import AppKit
import Foundation

/// What the Patch ROM sheet opens with: a link, a patch file, or a game to update.
struct PatchRequest: Identifiable {
    let id = UUID()
    var link: String = ""
    var file: URL?
    /// Set when updating a game already on the card, so the new build keeps its file name (and its save).
    var updating: Game?
}

/// Patch sources live on the Mac, next to the ratings database, keyed by the game's path under Roms.
enum PatchStore {
    static var url: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cartridge/patched.json")
    }

    static func load() -> [String: PatchSource] {
        guard let d = try? Data(contentsOf: url) else { return [:] }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return (try? dec.decode([String: PatchSource].self, from: d)) ?? [:]
    }

    static func save(_ s: [String: PatchSource]) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(s).write(to: url)
    }
}

extension AppModel {
    func openPatcher(link: String = "", file: URL? = nil, updating: Game? = nil) {
        guard snapshot != nil else { notice = "Insert the card first"; return }
        patchRequest = PatchRequest(link: link, file: file, updating: updating)
    }

    /// Patch files and GitHub links dropped on the window open the patcher instead of being copied.
    func isPatchDrop(_ u: URL) -> Bool {
        if u.isFileURL { return PatchFormat.fileExtensions.contains(u.pathExtension.lowercased()) }
        return u.host()?.hasSuffix("github.com") == true
    }

    func patchSource(for g: Game) -> PatchSource? { patchSources[g.relPath] }

    /// The game on the card a patched ROM with this name would replace, whatever its extension.
    func existingGame(named name: String, system: String) -> Game? {
        games.first { $0.system == system && !$0.isFolder && $0.stem.caseInsensitiveCompare(name) == .orderedSame }
    }

    /// Writes a patched ROM to the card. An update replaces the old file in place so the save, which Onion
    /// keys by file name, carries over. The ROM is written next to its final name first, so a pulled card
    /// never leaves half a game behind.
    func installPatched(rom: [UInt8], name: String, ext: String, system: String, cover: Data?, source: PatchSource) async throws {
        guard let s = snapshot else { throw PatchError("The card was ejected.") }
        let dir = s.roms.appendingPathComponent(system)
        let fileName = name + "." + ext
        let dest = dir.appendingPathComponent(fileName)
        let part = dir.appendingPathComponent("." + fileName + ".part")
        let replaced = existingGame(named: name, system: system)
        activity = Activity(title: replaced == nil ? "Adding to card" : "Updating on card", detail: "\(fileName) → \(SystemCatalog.info(for: system).name)")
        defer { activity = nil }

        try await Task.detached {
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? fm.removeItem(at: part)
            try Data(rom).write(to: part)
            if let old = replaced?.url { try CardWriter.unlockAndRemove(old) }
            if fm.fileExists(atPath: dest.path) { try CardWriter.unlockAndRemove(dest) }
            try fm.moveItem(at: part, to: dest)
        }.value
        CardWriter.removeAppleDouble(near: dest)

        if let cover {
            let imgs = dir.appendingPathComponent("Imgs")
            try? FileManager.default.createDirectory(at: imgs, withIntermediateDirectories: true)
            let art = imgs.appendingPathComponent(name + ".png")
            try? cover.write(to: art)
            CardWriter.removeAppleDouble(near: art)
        }
        CardWriter.invalidateCache(root: s.root, system: system)

        let rel = system + "/" + fileName
        if let old = replaced, old.relPath != rel { patchSources[old.relPath] = nil }
        patchSources[rel] = source
        PatchStore.save(patchSources)

        await refresh()
        // Keep a replaced game in Favorites under its new path.
        if let old = replaced, old.relPath != rel, var snap = snapshot, snap.favorites.remove(old.relPath) != nil {
            snap.favorites.insert(rel)
            try? CardWriter.writeFavorites(root: snap.root, games: snap.games.filter { snap.favorites.contains($0.relPath) },
                                           emulators: snap.emulators)
            snapshot = snap
        }
        selectedGame = rel
        notice = replaced == nil
            ? "Patched \(name)\(source.tag.map { " (\($0))" } ?? "") onto the card"
            : "Updated \(name)\(source.tag.map { " to \($0)" } ?? ""). Your save carries over."
    }
}
