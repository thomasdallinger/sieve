// Assertions and benchmarks for SieveCore.
//   swift run -c release sieve-check            correctness checks on a temporary tree
//   swift run -c release sieve-check --bench     also index and search your home folder
import Foundation
import SieveCore

var failures = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
    if condition() { return }
    failures += 1
    print("FAIL \(message) (line \(line))")
}
func time<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
    let start = CFAbsoluteTimeGetCurrent()
    let result = try body()
    print(String(format: "  %-44@ %8.2f ms", label as NSString, (CFAbsoluteTimeGetCurrent() - start) * 1000))
    return result
}

// Prompt tuning: swift run sieve-check --expand "rechnung" "vertrag" …
if let i = CommandLine.arguments.firstIndex(of: "--expand") {
    let model = LocalModel()
    for query in CommandLine.arguments[(i + 1)...] {
        let start = CFAbsoluteTimeGetCurrent()
        let semaphore = DispatchSemaphore(value: 0)
        Task {
            do { print("\(query) => \(try await model.expand(query)) (\(Int((CFAbsoluteTimeGetCurrent() - start) * 1000)) ms)") }
            catch { print("\(query) => error: \(error)") }
            semaphore.signal()
        }
        semaphore.wait()
    }
    exit(0)
}

// MARK: Folding and natural order
check(TextFold.fold("Résumé.PDF") == Array("resume.pdf".utf8), "fold strips case and accents")
check(TextFold.fold("ÄÖÜ ß") == TextFold.fold("aou ß"), "fold umlauts")
let natural = ["file10.txt", "file2.txt", "File1.txt", "file02.txt", "a", "B"].sorted {
    TextFold.naturalCompare(TextFold.fold($0), TextFold.fold($1)) < 0
}
check(natural == ["a", "B", "File1.txt", "file2.txt", "file02.txt", "file10.txt"], "natural order: \(natural)")

// MARK: Query parsing and scoring
let q = SearchQuery("Report  \"Q3 final\" report")
check(q.tokens.count == 2, "dedupe tokens and keep quoted phrase: \(q.tokens.map { String(decoding: $0, as: UTF8.self) })")
check(SearchQuery("inv").matches("Rechnung_INVOICE_2024.pdf"), "contains matches mid-word, any case")
check(!SearchQuery("invoice 2023").matches("invoice_2024.pdf"), "all tokens must match")
check(SearchQuery("2024 invoice").matches("invoice_2024.pdf"), "token order does not matter")
check(SearchQuery("café").matches("CAFE menu.txt"), "accent-insensitive")
func score(_ q: String, _ name: String, depth: Int = 1) -> Int32 {
    let f = TextFold.fold(name)
    return f.withUnsafeBufferPointer { SearchQuery(q).score($0, depth: depth, isDirectory: false, ageDays: 400) }
}
check(score("budget", "budget.xlsx") > score("budget", "old budget.xlsx"), "stem-exact beats word match")
check(score("budget", "old budget.xlsx") > score("budget", "superbudgetary.xlsx"), "word boundary beats mid-word")
check(score("budget", "budget.xlsx", depth: 1) > score("budget", "budget.xlsx", depth: 8), "shallow beats deep")
let hl = SearchQuery("resume").highlightRanges(in: "My Résumé.pdf")
check(hl.count == 1 && String("My Résumé.pdf"[hl[0]]) == "Résumé", "highlight ranges are accent-insensitive")

// MARK: Sorting and filtering
func item(_ name: String, dir: Bool = false, size: Int64 = 0, modified: Double = 0) -> FileItem {
    FileItem(path: "/x/" + name, name: name, type: dir ? .directory : .file, isContainer: dir, isPackage: false,
             isHidden: name.hasPrefix("."), size: size, created: modified, modified: modified, added: 0)
}
let items = [item("b.txt", size: 5, modified: 30), item("Zeta", dir: true, modified: 10), item("a10.txt", size: 50, modified: 20),
             item("a2.txt", size: 1, modified: 40), item(".hidden")]
var order = SortRule()
check(order.sorted(items).map(\.name) == ["Zeta", ".hidden", "a2.txt", "a10.txt", "b.txt"], "name sort, folders first")
order.select(.modified)
check(!order.ascending, "dates default to newest first")
check(order.sorted(items).map(\.name).dropFirst() == ["a2.txt", "b.txt", "a10.txt", ".hidden"], "modified newest first")
order.select(.modified)
check(order.ascending, "picking the active key flips direction")
order = SortRule(key: .size, ascending: false, foldersFirst: false)
check(order.sorted(items).first?.name == "a10.txt", "size largest first")
var filter = FilterOptions()
check(!filter.matches(item(".hidden"), browsing: true), "hidden files hidden by default")
filter.categories = [.image]
check(filter.matches(item("Zeta", dir: true), browsing: true), "folders stay visible while browsing")
check(!filter.matches(item("Zeta", dir: true), browsing: false), "folders drop out of filtered search")
check(filter.matches(item("pic.HEIC"), browsing: true) && !filter.matches(item("notes.txt"), browsing: true), "image filter")
check(FileCategory.categories(forExtension: "ts") == [.code], "ts is TypeScript, not video")
check(FileCategory.categories(forExtension: "mp4").contains(.video), "mp4 is video")
check(item("Movie.final.MP4").displayParts == ("Movie.final", ".MP4"), "extension always split off for display")
check(item("my.folder", dir: true).displayParts == ("my.folder", ""), "folders keep their dots")

// MARK: Directory reader and index on a temporary tree
let root = NSTemporaryDirectory() + "sieve-check-\(getpid())"
let fm = FileManager.default
try? fm.removeItem(atPath: root)
let layout = [
    "Invoices/2024/Rechnung Jänner.pdf", "Invoices/2024/invoice-march.PDF", "Invoices/old/inv_2019.pdf",
    "Photos/Urlaub Kroatien/IMG_0001.HEIC", "Photos/Urlaub Kroatien/IMG_0002.HEIC", "Photos/.thumbs/x.jpg",
    "Code/app/node_modules/left-pad/index.js", "Code/app/src/invoiceService.ts", "Code/App.app/Contents/Info.plist",
    "notes/meeting notes.md", "notes/Résumé.pdf",
]
for path in layout {
    let full = root + "/" + path
    try! fm.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    fm.createFile(atPath: full, contents: Data(repeating: 1, count: path.count))
}
var listed: [String] = []
try! DirectoryReader.scan(root + "/Invoices/2024") { listed.append(String(decoding: $0.name, as: UTF8.self)) }
check(Set(listed) == ["Rechnung Jänner.pdf", "invoice-march.PDF"], "reader lists entries: \(listed)")
let fmCount = try! fm.contentsOfDirectory(atPath: NSHomeDirectory()).count
var readerCount = 0
try! DirectoryReader.scan(NSHomeDirectory()) { _ in readerCount += 1 }
check(fmCount == readerCount, "reader matches FileManager on home (\(readerCount) vs \(fmCount))")
let listing = try! DirectoryListing.load(root + "/Code")
check(listing.first { $0.name == "App.app" }?.isPackage == true, "App.app is a package")

let index = FileIndex(roots: [root], exclusions: IndexExclusions(names: ["node_modules"], paths: []))
index.build()
func names(_ query: String, scope: String? = nil, filter: FilterOptions = FilterOptions()) -> [String] {
    let outcome = index.search(SearchQuery(query), options: .init(scopePath: scope.map { root + "/" + $0 }, filter: filter))
    return outcome.entries.map(\.name)
}
check(names("inv").sorted() == ["Invoices", "inv_2019.pdf", "invoice-march.PDF", "invoiceService.ts"], "contains search: \(names("inv"))")
check(names("jänner") == ["Rechnung Jänner.pdf"] && names("JANNER") == ["Rechnung Jänner.pdf"], "accent-insensitive search")
check(names("img heic").count == 2, "multi-token search")
check(names("x.jpg").isEmpty, "hidden folders excluded by default")
var showHidden = FilterOptions(); showHidden.showHidden = true
check(names("x.jpg", filter: showHidden) == ["x.jpg"], "hidden folders included when asked")
check(names("left-pad").isEmpty && names("node_modules") == ["node_modules"], "excluded folders are listed but not descended")
check(names("info.plist").isEmpty, "packages are not descended")
check(names("inv", scope: "Invoices/2024").sorted() == ["invoice-march.PDF"], "scoped search: \(names("inv", scope: "Invoices/2024"))")
var pdfOnly = FilterOptions(); pdfOnly.categories = [.pdf]
check(names("inv", filter: pdfOnly).sorted() == ["inv_2019.pdf", "invoice-march.PDF"], "kind filter in search")
check(names("invoice").first == "invoice-march.PDF" || names("invoice").first == "Invoices", "best match first: \(names("invoice"))")
check(index.search(SearchQuery("résumé"), options: .init()).entries.first?.path == root + "/notes/Résumé.pdf", "path reconstruction")
check(index.recentFiles(limit: 0).isEmpty && index.recentFiles(limit: 3).count == 3, "recent files, including limit 0")

// A folder we can't read keeps its contents (only ENOENT means gone).
chmod(root + "/Photos/Urlaub Kroatien", 0)
index.applyChanges([(root + "/Photos/Urlaub Kroatien", false)])
check(names("img heic").count == 2, "unreadable folder keeps its entries")
chmod(root + "/Photos/Urlaub Kroatien", 0o755)

// Live updates
try! fm.moveItem(atPath: root + "/notes/meeting notes.md", toPath: root + "/notes/standup notes.md")
try! fm.createDirectory(atPath: root + "/notes/new/deeper", withIntermediateDirectories: true)
fm.createFile(atPath: root + "/notes/new/deeper/fresh-invoice.txt", contents: nil)
try! fm.removeItem(atPath: root + "/Invoices/old")
index.applyChanges([(root + "/notes", false), (root + "/Invoices", false)])
check(names("meeting").isEmpty && names("standup") == ["standup notes.md"], "rename picked up")
check(names("fresh-invoice") == ["fresh-invoice.txt"], "new nested folder walked")
check(names("inv_2019").isEmpty, "deleted folder contents gone")
let fresh = index.search(SearchQuery("fresh-invoice"), options: .init()).entries.first
check(fresh?.path == root + "/notes/new/deeper/fresh-invoice.txt", "new entry path: \(fresh?.path ?? "nil")")

// Repeated full re-walks (FSEvents MustScanSubDirs) must not grow the index.
let before = index.count
for _ in 0..<3 { index.applyChanges([(root, true)]) }
check(index.count == before, "subtree rescans keep the entry count (\(before) → \(index.count))")
check(names("standup") == ["standup notes.md"] && names("fresh-invoice") == ["fresh-invoice.txt"], "search after subtree rescans")

// Cache round trip
let cacheURL = URL(fileURLWithPath: root + ".cache")
index.lastEventID = 4242
try! index.save(to: cacheURL)
let loaded = FileIndex(roots: [root], exclusions: IndexExclusions(names: ["node_modules"], paths: []))
check(loaded.load(from: cacheURL) != nil, "cache loads")
check(loaded.lastEventID == 4242 && loaded.count == index.count, "cache keeps entries and event id")
check(loaded.id(forDirectory: root + "/notes/new/deeper") != nil, "cache rebuilds directory map")
let goodCache = try! Data(contentsOf: cacheURL)
let other = FileIndex(roots: [root], exclusions: IndexExclusions(names: [], paths: []))
check(other.load(from: cacheURL) == nil, "cache with other exclusions is rejected")
// Corrupt caches are rejected (and deleted) instead of crashing.
func rejects(_ data: Data, _ label: String) {
    try! data.write(to: cacheURL)
    let probe = FileIndex(roots: [root], exclusions: IndexExclusions(names: ["node_modules"], paths: []))
    check(probe.load(from: cacheURL) == nil && !fm.fileExists(atPath: cacheURL.path), "corrupt cache rejected: \(label)")
}
rejects(goodCache.prefix(goodCache.count / 2), "truncated")
var huge = goodCache
let fpOffset = 4 + 8 + 8
huge.replaceSubrange(fpOffset..<fpOffset + 8, with: withUnsafeBytes(of: UInt64.max) { Data($0) })
rejects(huge, "absurd length")
// Flip bytes deep inside the arrays (parent ids, offsets): validation must catch every one.
for position in stride(from: goodCache.count / 5, to: goodCache.count - 16, by: goodCache.count / 7) {
    var bad = goodCache
    bad[position] ^= 0x5A; bad[position + 1] ^= 0x7F
    try! bad.write(to: cacheURL)
    let probe = FileIndex(roots: [root], exclusions: IndexExclusions(names: ["node_modules"], paths: []))
    _ = probe.load(from: cacheURL) // must not crash; a flip in sizes/dates may legitimately pass
    _ = probe.search(SearchQuery("e"), options: .init())
}
try! goodCache.write(to: cacheURL)
index.compact()
check(names("standup") == ["standup notes.md"] && names("fresh-invoice") == ["fresh-invoice.txt"], "search after compaction")
let afterCompaction = index.search(SearchQuery("inv"), options: .init())
check(afterCompaction.entries.allSatisfy { SearchQuery("inv").matches($0.name) }, "resolved entries match the query")
try? fm.removeItem(atPath: root)
try? fm.removeItem(at: cacheURL)

// MARK: Local model term cleanup
check(LocalModel.cleanTerms(["Rechnung", "invoices", "file", "bill", "bill", "a"], query: "invoice") == ["rechnung", "bill"], "term cleanup")

print(failures == 0 ? "All checks passed." : "\(failures) check(s) failed.")

// MARK: Benchmarks on the real home folder
if CommandLine.arguments.contains("--bench") {
    print("\nBenchmarks")
    let home = FileIndex(roots: IndexManager.defaultRoots, exclusions: .standard())
    time("index home + /Applications") { home.build() }
    print("  entries: \(home.count)")
    for query in ["e", "invoice", "png", "readme", "2024 pdf", "zzqx"] {
        let outcome = time("search \"\(query)\"") { home.search(SearchQuery(query), options: .init()) }
        print("    \(outcome.total) matches")
    }
    _ = time("recent files (200)") { home.recentFiles(limit: 200, scopePath: NSHomeDirectory()) }
    let url = URL(fileURLWithPath: NSTemporaryDirectory() + "sieve-bench.bin")
    time("save cache") { try! home.save(to: url) }
    let reload = FileIndex(roots: IndexManager.defaultRoots, exclusions: .standard())
    _ = time("load cache") { reload.load(from: url) }
    if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int { print("  cache size: \(size / 1_000_000) MB") }
    try? FileManager.default.removeItem(at: url)
    var list: [FileItem] = []
    for dir in ["/usr/bin", NSHomeDirectory() + "/Downloads", "/Applications", "/tmp/qplay/big"] where FileManager.default.fileExists(atPath: dir) {
        for _ in 0..<2 { time("list \(dir) (\(list.count))") { list = try! DirectoryListing.load(dir) } }
    }
    time("sort \(list.count) items by name") { _ = SortRule().sorted(list) }
    time("filter \(list.count) items") { _ = list.filter { FilterOptions().matches($0, browsing: true) } }
    list = try! DirectoryListing.load("/usr/bin")
    time("sort \(list.count) items by name") { _ = SortRule().sorted(list) }
    time("FileManager list /usr/bin with keys") {
        _ = try! FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/usr/bin"),
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
    }
}
exit(failures == 0 ? 0 : 1)
