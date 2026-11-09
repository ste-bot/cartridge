import AppKit
import Foundation

enum LibraryMode: String, Hashable {
    case mine, catalog
}

enum Availability: String, CaseIterable, Identifiable {
    case all = "All", missing = "Not on card", onCard = "On card"
    var id: String { rawValue }
}

extension AppModel {
    /// LaunchBox id -> the game on the card that matched it.
    var owned: [Int: Game] {
        if let o = ownedCache { return o }
        var o: [Int: Game] = [:]
        for g in games { if let m = meta(for: g), o[m.id] == nil { o[m.id] = g } }
        ownedCache = o
        return o
    }

    func platforms(for scope: LibraryScope) -> [String] {
        switch scope {
        case .system(let f): return SystemCatalog.info(for: f).platforms
        case .all, .favorites:
            // Systems with an emulator or games on this card.
            let folders = Set(snapshot?.emulators.map(\.romFolder) ?? []).union(games.map(\.system))
            return Array(Set(folders.flatMap { SystemCatalog.info(for: $0).platforms }))
        }
    }

    /// The full catalog for a scope, before filters.
    func catalogEntries(_ scope: LibraryScope) -> [GameMeta] {
        let index = ratings
        return index?.catalog(platforms: platforms(for: scope)) ?? []
    }

    func catalogCoverage(_ scope: LibraryScope) -> (have: Int, total: Int) {
        let list = catalogEntries(scope)
        let o = owned
        return (list.filter { o[$0.id] != nil }.count, list.count)
    }

    func catalogGenres(_ scope: LibraryScope) -> [(name: String, count: Int)] {
        var c: [String: Int] = [:]
        for e in catalogEntries(scope) {
            for g in (e.genres ?? "").components(separatedBy: ";") {
                let t = g.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty { c[t, default: 0] += 1 }
            }
        }
        return c.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    static func weighted(_ m: GameMeta) -> Double {
        guard let r = m.rating, let n = m.ratingCount, n > 0 else { return -1 }
        return (r * Double(n) + 3.4 * 25) / (Double(n) + 25)
    }

    func visibleCatalog(_ scope: LibraryScope) -> [GameMeta] {
        var list = catalogEntries(scope)
        let o = owned
        switch availability {
        case .all: break
        case .missing: list = list.filter { o[$0.id] == nil }
        case .onCard: list = list.filter { o[$0.id] != nil }
        }
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty { list = list.filter { $0.name.lowercased().contains(q) || ($0.genres?.lowercased().contains(q) ?? false) } }
        if let genre { list = list.filter { ($0.genres ?? "").components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.contains(genre) } }
        if ratedOnly { list = list.filter { ($0.ratingCount ?? 0) > 0 } }
        switch sort {
        case .title, .size, .added: list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        case .rating: list.sort { (Self.weighted($0), $1.name) > (Self.weighted($1), $0.name) }
        case .year: list.sort { ($0.year ?? 9999, $0.name) < ($1.year ?? 9999, $1.name) }
        }
        return list
    }

    /// Which Roms folder a catalog entry belongs in on this card.
    func folder(for entry: GameMeta, scope: LibraryScope) -> String? {
        if case .system(let f) = scope { return f }
        let candidates = SystemCatalog.all.filter { $0.platforms.contains(entry.platform) }.map(\.folder)
        let withEmu = Set(snapshot?.emulators.map(\.romFolder) ?? [])
        return candidates.first { withEmu.contains($0) } ?? candidates.first { snapshot?.romFolders.contains($0) ?? false } ?? candidates.first
    }

    static func safeFileName(_ name: String) -> String {
        name.replacingOccurrences(of: ": ", with: " - ")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "?", with: "")
            .replacingOccurrences(of: "\"", with: "'")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Lets the user pick a ROM they already have for a catalog game, and puts it on the card under the catalog's name
    /// so its cover and details match.
    func addFromFile(for entry: GameMeta, scope: LibraryScope) {
        guard let s = snapshot, let folder = folder(for: entry, scope: scope) else { return }
        let info = SystemCatalog.info(for: folder)
        let exts = s.emulators.filter { $0.romFolder == folder }.reduce(into: Set<String>()) { $0.formUnion($1.extensions) }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = info.gameIsFolder
        panel.prompt = "Add to Card"
        panel.message = "Choose your file for “\(entry.name)”. It's saved to Roms/\(folder) as “\(Self.safeFileName(entry.name))”"
            + (exts.isEmpty ? "." : " (\(exts.sorted().map { "." + $0 }.joined(separator: ", "))).")
        guard panel.runModal() == .OK, let src = panel.url else { return }
        let ext = src.pathExtension
        if !exts.isEmpty, !info.gameIsFolder, !exts.contains(ext.lowercased()) {
            notice = "\(info.name) doesn't play .\(ext) files. Expected \(exts.sorted().map { "." + $0 }.joined(separator: ", "))."
            return
        }
        let name = Self.safeFileName(entry.name) + (ext.isEmpty ? "" : "." + ext)
        let dir = s.roms.appendingPathComponent(folder)
        let dest = dir.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: dest.path) else { notice = "“\(name)” is already on the card"; return }
        Task {
            activity = Activity(title: "Adding to card", detail: "\(name) → \(info.name)")
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try await Task.detached { try FileManager.default.copyItem(at: src, to: dest) }.value
                CardWriter.removeAppleDouble(near: dest)
                CardWriter.invalidateCache(root: s.root, system: folder)
                activity = nil
                await refresh()
                if let g = games.first(where: { $0.url.path == dest.path }) { await saveBoxArt(for: g) }
                notice = "Added \(entry.name) to \(info.name)"
            } catch {
                activity = nil
                notice = "Couldn't add \(entry.name): \(error.localizedDescription)"
            }
        }
    }
}
