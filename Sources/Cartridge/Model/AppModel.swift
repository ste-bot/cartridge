import AppKit
import SwiftUI

enum Pane: Hashable {
    case device, emulators, library(LibraryScope)
}

enum LibraryScope: Hashable {
    case all, favorites, system(String)
}

enum SortOrder: String, CaseIterable, Identifiable {
    case rating = "Rating", title = "Title", year = "Year", size = "Size", added = "Recently added"
    var id: String { rawValue }
}

struct Activity: Equatable {
    var title: String
    var detail: String
}

@MainActor @Observable
final class AppModel {
    var snapshot: CardSnapshot?
    var loading = false
    var section: Pane = .library(.all)
    var search = ""
    var sort: SortOrder = .rating
    var genre: String?            // nil = any
    var ratedOnly = false
    var noCoverOnly = false
    var selectedGame: Game.ID?
    var activity: Activity?
    var notice: String?

    var ratings: RatingsIndex?
    var ratingsStatus = "Not installed"
    var releases: [OnionRelease] = []
    var releaseError: String?

    @ObservationIgnored private var metaCache: [String: GameMeta?] = [:]

    init() {
        // Launch arguments for opening a specific screen, e.g. `-pane device` or `-pane system:GBA -select "GBA/Pokemon Emerald.gba"`.
        let d = UserDefaults.standard
        switch d.string(forKey: "pane") {
        case "device": section = .device
        case "emulators": section = .emulators
        case "favorites": section = .library(.favorites)
        case let p? where p.hasPrefix("system:"): section = .library(.system(String(p.dropFirst(7))))
        default: break
        }
        selectedGame = d.string(forKey: "select")
        noCoverOnly = d.bool(forKey: "nocover")
        Task { await loadRatings() }
        Task { await refresh() }
        Task { await loadReleases() }
        let nc = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            nc.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.refresh() }
            }
        }
    }

    // MARK: Card

    func refresh() async {
        guard let root = CardReader.findCards().first else { snapshot = nil; return }
        loading = true
        let snap = await Task.detached(priority: .userInitiated) { CardReader.read(root) }.value
        snapshot = snap
        metaCache = [:]
        loading = false
    }

    var games: [Game] { snapshot?.games ?? [] }

    func systems() -> [(info: SystemInfo, count: Int, bytes: Int64)] {
        guard let s = snapshot else { return [] }
        let grouped = Dictionary(grouping: s.games, by: \.system)
        return grouped.map { (SystemCatalog.info(for: $0.key), $0.value.count, $0.value.reduce(0) { $0 + $1.size }) }
            .sorted { $0.info.name < $1.info.name }
    }

    func meta(for g: Game) -> GameMeta? {
        // Read `ratings` first so every view that shows metadata re-renders when the database loads.
        let index = ratings
        if let m = metaCache[g.id] { return m }
        let m = index?.match(title: g.title, platforms: SystemCatalog.info(for: g.system).platforms)
        metaCache[g.id] = m
        return m
    }

    /// Rating shrunk toward the average by how few people rated it, so a single 5-star vote doesn't top the list.
    func score(_ g: Game) -> Double {
        guard let m = meta(for: g), let r = m.rating, let n = m.ratingCount, n > 0 else { return -1 }
        let prior = 3.4, weight = 25.0
        return (r * Double(n) + prior * weight) / (Double(n) + weight)
    }

    func isFavorite(_ g: Game) -> Bool { snapshot?.favorites.contains(g.relPath) ?? false }

    /// Games in a sidebar scope, before any filter-bar filters.
    func scopedGames(_ scope: LibraryScope) -> [Game] {
        switch scope {
        case .all: games
        case .favorites: games.filter(isFavorite)
        case .system(let s): games.filter { $0.system == s }
        }
    }

    func genres(of g: Game) -> [String] {
        (meta(for: g)?.genres ?? "").components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Genres present in a scope, most common first.
    func genreCounts(scope: LibraryScope) -> [(name: String, count: Int)] {
        var c: [String: Int] = [:]
        for g in scopedGames(scope) { for x in genres(of: g) { c[x, default: 0] += 1 } }
        return c.map { ($0.key, $0.value) }.sorted { $0.count > $1.count }
    }

    /// Games with no cover on the card, and how many of those LaunchBox has a cover for.
    func coverGaps(scope: LibraryScope) -> (missing: [Game], fillable: [Game]) {
        let missing = scopedGames(scope).filter { $0.artURL == nil }
        return (missing, missing.filter { meta(for: $0)?.boxArtURL != nil })
    }

    var filtersActive: Bool { genre != nil || ratedOnly || noCoverOnly }

    func clearFilters() { genre = nil; ratedOnly = false; noCoverOnly = false }

    func visibleGames(scope: LibraryScope) -> [Game] {
        var list = scopedGames(scope)
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.title.lowercased().contains(q) || (meta(for: $0)?.genres?.lowercased().contains(q) ?? false) }
        }
        if let genre { list = list.filter { genres(of: $0).contains(genre) } }
        if ratedOnly { list = list.filter { (meta(for: $0)?.ratingCount ?? 0) > 0 } }
        if noCoverOnly { list = list.filter { $0.artURL == nil } }
        switch sort {
        case .title: list.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .rating: list.sort { (score($0), $1.title) > (score($1), $0.title) }
        case .year: list.sort { (meta(for: $0)?.year ?? 9999) < (meta(for: $1)?.year ?? 9999) }
        case .size: list.sort { $0.size > $1.size }
        case .added: list.sort { $0.added > $1.added }
        }
        return list
    }

    // MARK: Library actions

    func toggleFavorite(_ g: Game) {
        guard var s = snapshot else { return }
        if s.favorites.contains(g.relPath) { s.favorites.remove(g.relPath) } else { s.favorites.insert(g.relPath) }
        let favGames = s.games.filter { s.favorites.contains($0.relPath) }
        do {
            try CardWriter.writeFavorites(root: s.root, games: favGames, emulators: s.emulators)
            snapshot = s
            notice = s.favorites.contains(g.relPath) ? "Added \(g.title) to Favorites" : "Removed \(g.title) from Favorites"
        } catch { notice = "Couldn't update Favorites: \(error.localizedDescription)" }
    }

    func delete(_ g: Game) {
        guard var s = snapshot else { return }
        do {
            try CardWriter.unlockAndRemove(g.url)
            if let art = g.artURL { try? FileManager.default.removeItem(at: art) }
            CardWriter.invalidateCache(root: s.root, system: g.system)
            s.games.removeAll { $0.id == g.id }
            if s.favorites.remove(g.relPath) != nil {
                try? CardWriter.writeFavorites(root: s.root, games: s.games.filter { s.favorites.contains($0.relPath) }, emulators: s.emulators)
            }
            s.freeBytes += g.size
            snapshot = s
            if selectedGame == g.id { selectedGame = nil }
            notice = "Deleted \(g.title)"
        } catch { notice = "Couldn't delete \(g.title): \(error.localizedDescription)" }
    }

    /// Systems whose emulators accept this file extension.
    func systemsAccepting(_ url: URL) -> [String] {
        guard let s = snapshot else { return [] }
        let ext = url.pathExtension.lowercased()
        let generic: Set<String> = ["zip", "7z", "bin", "iso", "chd", "cue", "rar"]
        let matches = Set(s.emulators.filter { $0.extensions.contains(ext) }.map(\.romFolder))
        // Prefer the system that "owns" an extension (gba -> GBA, not GB) when there is a dedicated one.
        let owners: [String: String] = ["gba": "GBA", "gb": "GB", "gbc": "GBC", "nes": "FC", "fds": "FC", "sfc": "SFC", "smc": "SFC",
                                        "md": "MD", "gen": "MD", "smd": "MD", "sms": "MS", "gg": "GG", "nds": "NDS",
                                        "pce": "PCE", "ngp": "NGP", "ngc": "NGP", "32x": "THIRTYTWOX", "p8": "PICO", "pbp": "PS"]
        if let o = owners[ext], matches.contains(o) || s.romFolders.contains(o) { return [o] }
        if generic.contains(ext) { return matches.sorted() }
        return matches.sorted()
    }

    func addGames(_ urls: [URL], to forcedSystem: String? = nil) async {
        guard let s = snapshot else { return }
        var added = 0, skipped: [String] = []
        activity = Activity(title: "Adding games", detail: "")
        for u in urls {
            let targets = forcedSystem.map { [$0] } ?? systemsAccepting(u)
            guard targets.count == 1, let sys = targets.first else { skipped.append(u.lastPathComponent); continue }
            let destDir = s.roms.appendingPathComponent(sys)
            let dest = destDir.appendingPathComponent(u.lastPathComponent)
            activity?.detail = "\(u.lastPathComponent) → \(SystemCatalog.info(for: sys).name)"
            do {
                try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
                if FileManager.default.fileExists(atPath: dest.path) { skipped.append(u.lastPathComponent); continue }
                try await Task.detached { try FileManager.default.copyItem(at: u, to: dest) }.value
                CardWriter.removeAppleDouble(near: dest)
                CardWriter.invalidateCache(root: s.root, system: sys)
                added += 1
            } catch { skipped.append(u.lastPathComponent) }
        }
        activity = nil
        await refresh()
        notice = skipped.isEmpty
            ? "Added \(added) game\(added == 1 ? "" : "s")"
            : "Added \(added). Couldn't place: \(skipped.joined(separator: ", ")) — drop it onto a system in the sidebar."
    }

    /// Downloads LaunchBox box art and saves it where Onion looks for it.
    func saveBoxArt(for g: Game) async {
        guard let s = snapshot, let url = meta(for: g)?.boxArtURL else { return }
        do {
            let (d, _) = try await URLSession.shared.data(from: url)
            guard let img = NSImage(data: d), let png = img.resizedPNG(maxSide: 250) else { return }
            let dir = s.roms.appendingPathComponent(g.system).appendingPathComponent("Imgs")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent(g.stem + ".png")
            try png.write(to: dest)
            CardWriter.removeAppleDouble(near: dest)
            if var snap = snapshot, let i = snap.games.firstIndex(where: { $0.id == g.id }) {
                let old = snap.games[i]
                snap.games[i] = Game(system: old.system, relPath: old.relPath, fileName: old.fileName, title: old.title, url: old.url,
                                     size: old.size, isFolder: old.isFolder, added: old.added, artURL: dest)
                snapshot = snap
            }
        } catch { notice = "Couldn't save box art: \(error.localizedDescription)" }
    }

    func saveCovers(scope: LibraryScope) async {
        let fillable = coverGaps(scope: scope).fillable
        guard !fillable.isEmpty else { notice = "No covers to save"; return }
        for (i, g) in fillable.enumerated() {
            activity = Activity(title: "Saving covers", detail: "\(i + 1) of \(fillable.count) · \(g.title)")
            await saveBoxArt(for: g)
        }
        activity = nil
        notice = "Saved \(fillable.count) covers to the card"
    }

    /// Lets the user pick ROMs, telling them where they'll go.
    func chooseGamesToAdd(scope: LibraryScope) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Add to Card"
        if case .system(let f) = scope {
            panel.message = "Adding to \(SystemCatalog.info(for: f).name). Files go in Roms/\(f) on the card."
        } else {
            panel.message = "Each file goes to its system's folder based on its extension (.gba → Game Boy Advance)."
        }
        guard panel.runModal() == .OK else { return }
        let forced: String? = { if case .system(let f) = scope { return f } else { return nil } }()
        Task { await addGames(panel.urls, to: forced) }
    }

    // MARK: Ratings

    func loadRatings() async {
        if let idx = await Task.detached(operation: { RatingsIndex.load() }).value {
            ratings = idx
            ratingsStatus = "\(idx.entries.count.formatted()) games · updated \(idx.built.formatted(date: .abbreviated, time: .omitted))"
            metaCache = [:]
        } else if FileManager.default.fileExists(atPath: RatingsIndex.zipURL.path) {
            await buildRatings()
        }
    }

    func downloadRatings() async {
        activity = Activity(title: "Ratings database", detail: "Downloading 110 MB from LaunchBox…")
        do {
            let (tmp, _) = try await URLSession.shared.download(from: RatingsIndex.downloadURL)
            try? FileManager.default.removeItem(at: RatingsIndex.zipURL)
            try FileManager.default.moveItem(at: tmp, to: RatingsIndex.zipURL)
            await buildRatings()
        } catch {
            activity = nil
            notice = "Couldn't download ratings: \(error.localizedDescription)"
        }
    }

    func buildRatings() async {
        activity = Activity(title: "Ratings database", detail: "Preparing…")
        do {
            let idx = try await RatingsIndex.build(fromZip: RatingsIndex.zipURL, platforms: SystemCatalog.allPlatforms) { msg in
                Task { @MainActor in self.activity?.detail = msg }
            }
            ratings = idx
            metaCache = [:]
            ratingsStatus = "\(idx.entries.count.formatted()) games · updated \(idx.built.formatted(date: .abbreviated, time: .omitted))"
        } catch { notice = "Couldn't read the ratings database: \(error.localizedDescription)" }
        activity = nil
    }

    // MARK: OS

    func loadReleases() async {
        do { releases = try await OnionUpdates.fetchReleases(); releaseError = nil }
        catch { releaseError = "Couldn't reach GitHub" }
    }

    var latestStable: OnionRelease? { releases.first { !$0.prerelease } }
    var latestBeta: OnionRelease? { releases.first { $0.prerelease } }

    func stageUpdate(_ r: OnionRelease) async {
        guard let s = snapshot else { return }
        activity = Activity(title: "Onion \(r.version)", detail: "Starting…")
        do {
            try await OnionUpdates.stage(r, onto: s.root) { msg in Task { @MainActor in self.activity?.detail = msg } }
            notice = "Onion \(r.version) is on the card. Eject, then turn the Miyoo on to install."
        } catch { notice = "Update failed: \(error.localizedDescription)" }
        activity = nil
        await refresh()
    }

    func backUp() async {
        guard let s = snapshot else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Back Up Here"
        panel.message = "Choose where to save a full copy of the card."
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        activity = Activity(title: "Backing up", detail: "Starting…")
        do {
            let dest = try await Backup.run(card: s.root, to: dir) { n in
                Task { @MainActor in self.activity?.detail = "\(n.formatted()) files copied" }
            }
            notice = "Backed up to \(dest.lastPathComponent)"
            NSWorkspace.shared.activateFileViewerSelecting([dest])
        } catch { notice = "Backup failed: \(error.localizedDescription)" }
        activity = nil
    }

    func eject() {
        guard let s = snapshot else { return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: s.root)
            snapshot = nil
            notice = "Ejected. It's safe to remove the card."
        } catch { notice = "Couldn't eject: \(error.localizedDescription)" }
    }

    // MARK: Emulators

    func isInstalled(_ p: PackageInfo) -> Bool {
        guard let s = snapshot else { return false }
        return p.targets.allSatisfy { FileManager.default.fileExists(atPath: s.root.appendingPathComponent($0).path) }
    }

    func install(_ p: PackageInfo) async {
        guard let s = snapshot else { return }
        activity = Activity(title: "Installing", detail: p.title)
        do {
            try await Shell.run("/usr/bin/rsync", ["-rt", p.url.path + "/", s.root.path + "/"])
            notice = "Installed \(p.title)"
        } catch { notice = "Couldn't install \(p.title): \(error.localizedDescription)" }
        activity = nil
        await refresh()
    }

    func uninstall(_ p: PackageInfo) async {
        guard let s = snapshot else { return }
        for t in p.targets where t.hasPrefix("Emu/") || t.hasPrefix("RApp/") {
            try? CardWriter.unlockAndRemove(s.root.appendingPathComponent(t))
        }
        notice = "Removed \(p.title). Its games stay on the card."
        await refresh()
    }

    func biosStatus(for info: SystemInfo) -> [BiosStatus] {
        let files = snapshot?.biosFiles ?? []
        return info.bios.map { req in BiosStatus(requirement: req, found: req.files.first { files.contains($0.lowercased()) }) }
    }
}

extension NSImage {
    func resizedPNG(maxSide: CGFloat) -> Data? {
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = NSSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(target.width), pixelsHigh: Int(target.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        draw(in: NSRect(origin: .zero, size: target))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
