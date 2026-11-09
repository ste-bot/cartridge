import Foundation

/// One game from the LaunchBox Games Database.
struct GameMeta: Codable, Hashable {
    var id: Int
    var name: String
    var platform: String
    var year: Int?
    var rating: Double?          // 0–5 community rating
    var ratingCount: Int?
    var genres: String?
    var developer: String?
    var publisher: String?
    var players: Int?
    var overview: String?
    var wikipedia: String?
    var video: String?
    var boxArt: String?          // file name on images.launchbox-app.com
    var altNames: [String]?
    var releaseType: String?     // Released, Unlicensed, Homebrew, ROM Hack, Unreleased…

    /// Shown in the catalog: games that came out commercially (licensed or not).
    var isCatalogRelease: Bool { releaseType == nil || releaseType == "Released" || releaseType == "Unlicensed" }

    var boxArtURL: URL? { boxArt.flatMap { URL(string: "https://images.launchbox-app.com/\($0)") } }
    var launchBoxURL: URL? { URL(string: "https://gamesdb.launchbox-app.com/games/details/\(id)") }
}

enum TitleKey {
    private static let roman: [String: String] = ["ii": "2", "iii": "3", "iv": "4", "vi": "6", "vii": "7", "viii": "8", "ix": "9"]

    static func normalize(_ s: String) -> String {
        var t = s.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil).lowercased()
        t = t.replacing(#/\([^)]*\)|\[[^\]]*\]/#, with: " ")
        t = t.replacingOccurrences(of: "&", with: " and ")
        t = String(t.map { $0.isLetter || $0.isNumber ? $0 : " " })
        var tokens = t.split(separator: " ").map(String.init)
        if tokens.first == "the" { tokens.removeFirst() }
        if tokens.last == "version" { tokens.removeLast() }
        tokens = tokens.map { roman[$0] ?? $0 }
        return tokens.joined(separator: " ")
    }

    /// Keys to try for a filename, most specific first.
    static func candidates(for title: String) -> [String] {
        var out: [String] = []
        let full = normalize(title)
        out.append(full)
        if full.hasSuffix(" 1") { out.append(String(full.dropLast(2))) }
        for sep in [" - ", ": ", " _ "] where title.contains(sep) {
            out.append(normalize(String(title.components(separatedBy: sep)[0])))
        }
        return out.filter { !$0.isEmpty }
    }

    static func subtitleLess(_ name: String) -> String? {
        for sep in [": ", " - "] where name.contains(sep) { return normalize(String(name.components(separatedBy: sep)[0])) }
        return nil
    }
}

/// The on-disk index plus lookup tables.
final class RatingsIndex: @unchecked Sendable {
    let built: Date
    let entries: [GameMeta]
    private var exact: [String: [String: Int]] = [:]    // platform -> key -> entry index
    private var loose: [String: [String: Int]] = [:]

    struct File: Codable { var version: Int?; var built: Date; var entries: [GameMeta] }
    static let formatVersion = 2

    init(file: File) {
        built = file.built
        entries = file.entries
        for (i, e) in entries.enumerated() {
            func put(_ dict: inout [String: [String: Int]], _ key: String) {
                guard !key.isEmpty else { return }
                if let j = dict[e.platform]?[key], (entries[j].ratingCount ?? 0) >= (e.ratingCount ?? 0) { return }
                dict[e.platform, default: [:]][key] = i
            }
            put(&exact, TitleKey.normalize(e.name))
            for a in e.altNames ?? [] { put(&exact, TitleKey.normalize(a)) }
            if let s = TitleKey.subtitleLess(e.name) { put(&loose, s) }
        }
    }

    func match(title: String, platforms: [String]) -> GameMeta? {
        let keys = TitleKey.candidates(for: title)
        for table in [exact, loose] {
            for k in keys {
                for p in platforms { if let i = table[p]?[k] { return entries[i] } }
            }
        }
        return nil
    }

    private var catalogCache: [String: [GameMeta]] = [:]

    /// Every commercially released game for these platforms (no homebrew, hacks, unreleased or DLC).
    func catalog(platforms: [String]) -> [GameMeta] {
        let key = platforms.sorted().joined(separator: "|")
        if let c = catalogCache[key] { return c }
        let set = Set(platforms)
        let list = entries.filter { set.contains($0.platform) && $0.isCatalogRelease }
        catalogCache[key] = list
        return list
    }

    static var directory: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Cartridge")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    static var indexURL: URL { directory.appendingPathComponent("ratings-index.json") }
    static var zipURL: URL { directory.appendingPathComponent("Metadata.zip") }
    static let downloadURL = URL(string: "https://gamesdb.launchbox-app.com/Metadata.zip")!

    static func load() -> RatingsIndex? {
        guard let d = try? Data(contentsOf: indexURL) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        guard let f = try? dec.decode(File.self, from: d), f.version == formatVersion else { return nil }
        return RatingsIndex(file: f)
    }

    /// Unzips Metadata.xml from the LaunchBox zip and builds a compact index for the systems we care about.
    static func build(fromZip zip: URL, platforms: Set<String>, progress: @escaping @Sendable (String) -> Void) async throws -> RatingsIndex {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("cartridge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        progress("Unpacking database…")
        try await Shell.run("/usr/bin/unzip", ["-o", "-q", zip.path, "Metadata.xml", "-d", tmp.path])
        progress("Reading 500 MB of game data…")
        let parser = LaunchBoxParser(platforms: platforms)
        let entries = try await Task.detached(priority: .userInitiated) { try parser.parse(tmp.appendingPathComponent("Metadata.xml")) }.value
        let file = File(version: formatVersion, built: Date(), entries: entries)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        try enc.encode(file).write(to: indexURL)
        progress("Indexed \(entries.count.formatted()) games")
        return RatingsIndex(file: file)
    }
}

/// Streaming SAX parser over LaunchBox's Metadata.xml.
final class LaunchBoxParser: NSObject, XMLParserDelegate, @unchecked Sendable {
    let platforms: Set<String>
    private var entries: [Int: GameMeta] = [:]
    private var alts: [Int: [String]] = [:]
    private var images: [Int: (file: String, rank: Int)] = [:]
    private var record: String?
    private var fields: [String: String] = [:]
    private var text = ""

    init(platforms: Set<String>) { self.platforms = platforms }

    func parse(_ url: URL) throws -> [GameMeta] {
        guard let p = XMLParser(contentsOf: url) else { throw CocoaError(.fileReadCorruptFile) }
        p.delegate = self
        guard p.parse() else { throw p.parserError ?? CocoaError(.fileReadCorruptFile) }
        var out: [GameMeta] = []
        out.reserveCapacity(entries.count)
        for (id, var e) in entries {
            e.altNames = alts[id]
            e.boxArt = images[id]?.file
            out.append(e)
        }
        return out.sorted { $0.id < $1.id }
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if record == nil {
            if name == "Game" || name == "GameAlternateName" || name == "GameImage" { record = name; fields = [:] }
        } else { text = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if record != nil { text += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard let r = record else { return }
        if name != r { fields[name] = text; return }
        record = nil
        guard let id = fields["DatabaseID"].flatMap(Int.init) else { return }
        switch r {
        case "Game":
            guard let plat = fields["Platform"], platforms.contains(plat), let n = fields["Name"] else { return }
            let year = fields["ReleaseYear"].flatMap(Int.init) ?? fields["ReleaseDate"].flatMap { Int($0.prefix(4)) }
            let ov = fields["Overview"].map { $0.count > 1200 ? String($0.prefix(1200)) + "…" : $0 }
            entries[id] = GameMeta(id: id, name: n, platform: plat, year: year,
                                   rating: fields["CommunityRating"].flatMap(Double.init),
                                   ratingCount: fields["CommunityRatingCount"].flatMap(Int.init),
                                   genres: fields["Genres"].flatMap { $0.isEmpty ? nil : $0 },
                                   developer: fields["Developer"], publisher: fields["Publisher"],
                                   players: fields["MaxPlayers"].flatMap(Int.init), overview: ov,
                                   wikipedia: fields["WikipediaURL"], video: fields["VideoURL"],
                                   releaseType: fields["ReleaseType"])
        case "GameAlternateName":
            if let a = fields["AlternateName"] { alts[id, default: []].append(a) }
        case "GameImage":
            guard fields["Type"] == "Box - Front", let f = fields["FileName"] else { return }
            let rank: Int
            switch fields["Region"] {
            case "North America": rank = 0
            case nil, "": rank = 1
            case "World": rank = 2
            case "Europe": rank = 3
            default: rank = 4
            }
            if let cur = images[id], cur.rank <= rank { return }
            images[id] = (f, rank)
        default: break
        }
    }
}
