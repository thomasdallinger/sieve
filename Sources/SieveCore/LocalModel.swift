import Foundation

/// Talks to a local Ollama server. Sieve uses a small model only to suggest *other* words a relevant file name
/// might contain (synonyms, translations, abbreviations); those words then go through the same literal
/// contains search, so every AI result still visibly matches something.
public final class LocalModel: @unchecked Sendable {
    public static let defaultModel = "qwen3.5:2b-q4_K_M"
    public static let defaultModelSize = "1.9 GB"

    public enum Status: Equatable, Sendable {
        case unknown
        case serverNotRunning
        case modelMissing
        case downloading(Double)
        case ready
        case failed(String)
    }

    /// The Ollama model tag. Changed from Settings on the main thread, read by requests in flight.
    public var model: String {
        get { cacheLock.withLock { _model } }
        set { cacheLock.withLock { if newValue != _model { _model = newValue; cache = [:] } } }
    }
    private var _model: String
    public let baseURL: URL
    private let session: URLSession
    private let cacheLock = NSLock()
    private var cache: [String: [String]] = [:]

    public init(model: String = LocalModel.defaultModel, baseURL: URL = URL(string: "http://127.0.0.1:11434")!) {
        _model = model
        self.baseURL = baseURL
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    // MARK: Status and setup

    public func status() async -> Status {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return .serverNotRunning }
        struct Tags: Decodable { struct M: Decodable { let name: String; let model: String? }; let models: [M] }
        let names = (try? JSONDecoder().decode(Tags.self, from: data))?.models.flatMap { [$0.name, $0.model ?? ""] } ?? []
        let wanted = model.contains(":") ? model : model + ":latest"
        return names.contains(wanted) || names.contains(model) ? .ready : .modelMissing
    }

    /// Paths where an `ollama` binary usually lives (Homebrew on Apple silicon and Intel, the Ollama app).
    public static var ollamaBinary: String? {
        ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama", "/Applications/Ollama.app/Contents/Resources/ollama"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Starts `ollama serve` in the background when the binary is installed but the server is not running.
    @discardableResult
    public static func startServer() -> Bool {
        if FileManager.default.fileExists(atPath: "/Applications/Ollama.app") {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = ["-g", "-j", "/Applications/Ollama.app"]
            return (try? p.run()) != nil
        }
        guard let bin = ollamaBinary else { return false }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: bin)
        p.arguments = ["serve"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        return (try? p.run()) != nil
    }

    /// Downloads the model, reporting progress from 0 to 1.
    public func pull(progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/pull"))
        request.httpMethod = "POST"
        request.timeoutInterval = 3600
        request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "stream": true])
        let (bytes, _) = try await session.bytes(for: request)
        for try await line in bytes.lines {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if let error = obj["error"] as? String { throw NSError(domain: "Sieve", code: 1, userInfo: [NSLocalizedDescriptionKey: error]) }
            if let total = obj["total"] as? Double, total > 0, let done = obj["completed"] as? Double { progress(done / total) }
            if obj["status"] as? String == "success" { progress(1) }
        }
    }

    /// Loads the model into memory so the first real query does not pay the load time.
    public func warmUp() {
        Task.detached { [self] in
            var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
            request.httpMethod = "POST"
            request.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "keep_alive": "30m", "prompt": ""])
            _ = try? await session.data(for: request)
        }
    }

    // MARK: Query expansion

    private static let systemPrompt = """
    You help a Mac file search. The user typed a search. Reply with JSON {"terms": [...]}: up to 8 OTHER words \
    that the file name of a relevant file would likely contain. First the direct translations of the typed words (English, German, \
    Spanish, French), then exact synonyms and common abbreviations. Only words that mean the same thing, not merely related topics. \
    Each term: lowercase, 2-20 characters, one or two words. Never repeat the typed words or add generic words (file, document, new, copy, final).
    """

    private static let examples: [(String, [String])] = [
        ("invoice", ["rechnung", "bill", "receipt", "factura", "facture", "inv"]),
        ("vertrag", ["contract", "agreement", "vereinbarung", "contrato", "contrat"]),
        ("screenshot", ["bildschirmfoto", "screen shot", "capture", "screencap", "captura"]),
    ]

    private static let generic: Set<String> = [
        "file", "files", "document", "documents", "doc", "new", "copy", "final", "data", "folder", "item", "untitled",
        "image", "images", "photo", "photos", "text", "misc", "other", "stuff", "the", "and", "für", "und",
    ]

    /// Other name fragments worth searching for. Cached per query; throws when the server is unreachable.
    public func expand(_ query: String) async throws -> [String] {
        let key = query.lowercased().trimmingCharacters(in: .whitespaces)
        let model = self.model
        if let hit = cached(key) { return hit }

        var messages: [[String: String]] = [["role": "system", "content": Self.systemPrompt]]
        for (q, terms) in Self.examples {
            messages.append(["role": "user", "content": q])
            messages.append(["role": "assistant", "content": #"{"terms": [\#(terms.map { "\"\($0)\"" }.joined(separator: ", "))]}"#])
        }
        messages.append(["role": "user", "content": query])
        let body: [String: Any] = [
            "model": model, "stream": false, "think": false, "keep_alive": "30m", "format": "json",
            "options": ["temperature": 0.1, "num_predict": 120],
            "messages": messages,
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "Sieve", code: 2, userInfo: [NSLocalizedDescriptionKey: String(decoding: data, as: UTF8.self)])
        }
        let content = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? [String: Any])?["content"] as? String ?? ""
        let terms = Self.cleanTerms(Self.parseTerms(content), query: query)
        store(key, terms)
        return terms
    }

    private func cached(_ key: String) -> [String]? { cacheLock.withLock { cache[key] } }
    private func store(_ key: String, _ terms: [String]) { cacheLock.withLock { cache[key] = terms } }

    /// Small models wrap JSON in code fences or return objects instead of strings; accept all of it.
    static func parseTerms(_ content: String) -> [String] {
        if let open = content.firstIndex(of: "{"), let close = content.lastIndex(of: "}"), open < close,
           let obj = try? JSONSerialization.jsonObject(with: Data(content[open...close].utf8)) as? [String: Any] {
            let list = (obj["terms"] as? [Any]) ?? obj.values.compactMap { $0 as? [Any] }.first ?? []
            return list.compactMap { item in
                if let s = item as? String { return s }
                if let d = item as? [String: Any] { return d.values.compactMap { $0 as? String }.first }
                return nil
            }
        }
        // Fallback: one term per line or comma.
        return content.components(separatedBy: CharacterSet(charactersIn: "\n,"))
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " -*0123456789.\"'`[]")) }
    }

    public static func cleanTerms(_ raw: [String], query: String) -> [String] {
        let typed = SearchQuery(query)
        var seen = Set<String>()
        var out: [String] = []
        for term in raw {
            let t = term.lowercased().trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'`.")))
            guard t.count >= 2, t.count <= 24, !generic.contains(t), t.split(separator: " ").count <= 2 else { continue }
            // Skip terms the literal search already covers (they would only repeat literal hits).
            if typed.matches(t) { continue }
            if seen.insert(t).inserted { out.append(t) }
            if out.count == 10 { break }
        }
        return out
    }
}
