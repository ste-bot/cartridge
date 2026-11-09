import Foundation

// MARK: - Plain data read from the SD card

struct EmulatorConfig: Identifiable, Hashable {
    var id: String { dir.path }
    let dir: URL                 // e.g. <card>/Emu/GBA
    let kind: String             // "Emu" or "RApp"
    let label: String
    let romFolder: String        // e.g. "GBA" (relative to Roms)
    let extensions: Set<String>
    let core: String?            // e.g. "mgba"
    let iconPath: String?        // relative to card root
}

struct Game: Identifiable, Hashable {
    var id: String { relPath }
    let system: String           // Roms folder
    let relPath: String          // "GBA/Pokemon Emerald.gba" (relative to Roms)
    let fileName: String
    let title: String            // display title
    let url: URL
    let size: Int64
    let isFolder: Bool
    let added: Date
    let artURL: URL?             // local box art on the card
    var stem: String { (fileName as NSString).deletingPathExtension }
}

struct ThemeInfo: Identifiable, Hashable {
    var id: String { url.path }
    let name: String
    let url: URL
    var preview: URL { url.appendingPathComponent("preview.png") }
}

struct BiosStatus: Identifiable, Hashable {
    var id: String { requirement.files.joined() }
    let requirement: BiosRequirement
    let found: String?
}

struct PackageInfo: Identifiable, Hashable {
    var id: String { url.path }
    let name: String             // "Nintendo - GBA (mGBA)"
    let kind: String             // "Emu" / "RApp"
    let url: URL                 // package root inside PackageManager/data
    let targets: [String]        // e.g. ["Emu/GBA"] relative to card root
    var vendor: String { name.components(separatedBy: " - ").first ?? "Other" }
    var title: String {
        let parts = name.components(separatedBy: " - ")
        return parts.count > 1 ? parts.dropFirst().joined(separator: " - ") : name
    }
}

struct CardSnapshot {
    var root: URL
    var volumeName: String
    var osVersion: String
    var retroArchVersion: String?
    var updateStaged: Bool
    var totalBytes: Int64
    var freeBytes: Int64
    var emulators: [EmulatorConfig]
    var games: [Game]
    var romFolders: [String]
    var themes: [ThemeInfo]
    var activeThemePath: String?
    var favorites: Set<String>   // relPaths
    var packages: [PackageInfo]
    var biosFiles: Set<String>   // lower-cased relative paths inside /BIOS
    var systemIcons: [String: URL] // Roms folder -> hardware icon from the card's Icons/ pack

    var roms: URL { root.appendingPathComponent("Roms") }
    var usedBytes: Int64 { max(0, totalBytes - freeBytes) }
}

// MARK: - Reading

enum CardReader {
    static let skipNames: Set<String> = ["imgs", "imgs_hd", "manuals", "shortcuts", "games", ".res", ".game_config"]
    static let skipExt: Set<String> = ["db", "json", "png", "jpg", "txt", "xml", "cfg", "ini", "log", "miyoocmd", "dat"]

    /// Mounted volumes that look like an Onion card.
    static func findCards() -> [URL] {
        let fm = FileManager.default
        let vols = (try? fm.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: nil)) ?? []
        return vols.filter {
            fm.fileExists(atPath: $0.appendingPathComponent("Roms").path) &&
            (fm.fileExists(atPath: $0.appendingPathComponent(".tmp_update").path) ||
             fm.fileExists(atPath: $0.appendingPathComponent("miyoo").path))
        }
    }

    static func read(_ root: URL) -> CardSnapshot {
        let fm = FileManager.default
        let txt = { (p: String) -> String? in
            (try? String(contentsOf: root.appendingPathComponent(p), encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let values = try? root.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey, .volumeNameKey])

        let emus = readEmulators(root)
        let biosFiles = listBios(root)
        let arcadeNames = readArcadeNames(root)

        // ROM folders + games
        let romsURL = root.appendingPathComponent("Roms")
        let folders = ((try? fm.contentsOfDirectory(atPath: romsURL.path)) ?? [])
            .filter { !$0.hasPrefix(".") && isDir(romsURL.appendingPathComponent($0)) }
            .sorted()
        var games: [Game] = []
        for f in folders {
            let exts = emus.filter { $0.romFolder == f }.reduce(into: Set<String>()) { $0.formUnion($1.extensions) }
            games += scanFolder(romsURL, folder: f, exts: exts, arcadeNames: arcadeNames)
        }

        return CardSnapshot(
            root: root,
            volumeName: values?.volumeName ?? root.lastPathComponent,
            osVersion: txt(".tmp_update/onionVersion/version.txt") ?? "Unknown",
            retroArchVersion: txt("RetroArch/ra_package_version.txt") ?? txt("RetroArch/onion_ra_version.txt"),
            updateStaged: fm.fileExists(atPath: root.appendingPathComponent("miyoo/app/.tmp_update/onion.pak").path),
            totalBytes: Int64(values?.volumeTotalCapacity ?? 0),
            freeBytes: Int64(values?.volumeAvailableCapacity ?? 0),
            emulators: emus,
            games: games,
            romFolders: folders,
            themes: readThemes(root),
            activeThemePath: readActiveTheme(root),
            favorites: readFavorites(root),
            packages: readPackages(root),
            biosFiles: biosFiles,
            systemIcons: readSystemIcons(root, folders: Set(folders).union(emus.map(\.romFolder)), emulators: emus)
        )
    }

    /// Onion's icon file names for each Roms folder.
    static let iconNames: [String: String] = [
        "GB": "gb", "GBC": "gbc", "GBA": "gba", "FC": "fc", "SFC": "sfc", "NDS": "nds", "GW": "gw", "MD": "md", "MS": "ms",
        "GG": "gg", "SEGACD": "segacd", "THIRTYTWOX": "32X", "PS": "ps", "PCE": "pce", "NGP": "ngp", "NEOCD": "neocd",
        "ARCADE": "arcade", "FBNEO": "arcade", "FBA2012": "arcade", "MAME2000": "arcade", "ADVMAME": "arcade", "MBA": "arcade",
        "DOS": "dos", "SCUMMVM": "scummvm", "PICO": "pico", "PORTS": "ports",
    ]

    /// The default pack draws real hardware; prefer it over whatever stylised pack the device uses.
    static func readSystemIcons(_ root: URL, folders: Set<String>, emulators: [EmulatorConfig]) -> [String: URL] {
        let fm = FileManager.default
        var out: [String: URL] = [:]
        for f in folders {
            let candidates = [iconNames[f].map { root.appendingPathComponent("Icons/Default/\($0).png") },
                              emulators.first { $0.romFolder == f }?.iconPath.map { root.appendingPathComponent($0) }]
            if let hit = candidates.compactMap({ $0 }).first(where: { fm.fileExists(atPath: $0.path) }) { out[f] = hit }
        }
        return out
    }

    static func isDir(_ url: URL) -> Bool {
        var d: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &d) && d.boolValue
    }

    static func scanFolder(_ roms: URL, folder: String, exts: Set<String>, arcadeNames: [String: String]) -> [Game] {
        let fm = FileManager.default
        let info = SystemCatalog.info(for: folder)
        var base = roms.appendingPathComponent(folder)
        var relPrefix = folder
        if folder == "PORTS" { base = base.appendingPathComponent("Games"); relPrefix = "PORTS/Games" }
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey, .creationDateKey]
        guard let items = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        let isArcade = info.platforms == ["Arcade"]
        var out: [Game] = []
        for u in items {
            let name = u.lastPathComponent
            if name.hasPrefix("~") || name.hasPrefix("._") || skipNames.contains(name.lowercased()) { continue }
            let rv = try? u.resourceValues(forKeys: Set(keys))
            let dir = rv?.isDirectory ?? false
            let ext = u.pathExtension.lowercased()
            if dir {
                guard info.gameIsFolder || folder == "PORTS" else { continue }
            } else {
                if skipExt.contains(ext) || name.contains("_cache") { continue }
                if !exts.isEmpty && !exts.contains(ext) { continue }
            }
            let stem = dir ? name : (name as NSString).deletingPathExtension
            let title = isArcade ? (arcadeNames[stem] ?? stem) : stem
            let size = dir ? folderSize(u) : Int64(rv?.fileSize ?? 0)
            let art = roms.appendingPathComponent(folder).appendingPathComponent("Imgs").appendingPathComponent(stem + ".png")
            out.append(Game(system: folder, relPath: "\(relPrefix)/\(name)", fileName: name, title: title, url: u,
                            size: size, isFolder: dir, added: rv?.creationDate ?? .distantPast,
                            artURL: fm.fileExists(atPath: art.path) ? art : nil))
        }
        return out
    }

    static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var t: Int64 = 0
        for case let f as URL in e { t += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return t
    }

    static func readEmulators(_ root: URL) -> [EmulatorConfig] {
        var out: [EmulatorConfig] = []
        for kind in ["Emu", "RApp"] {
            let base = root.appendingPathComponent(kind)
            for d in (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                let cfg = d.appendingPathComponent("config.json")
                guard let data = try? Data(contentsOf: cfg),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let rompath = obj["rompath"] as? String else { continue }
                var parts = rompath.components(separatedBy: "/").filter { $0 != ".." && $0 != "." && !$0.isEmpty }
                guard parts.first == "Roms", parts.count >= 2 else { continue }
                parts.removeFirst()
                let ext = ((obj["extlist"] as? String) ?? "").lowercased().split(separator: "|").map(String.init)
                let launch = (try? String(contentsOf: d.appendingPathComponent("launch.sh"), encoding: .utf8)) ?? ""
                let core = launch.firstMatch(of: #/([a-z0-9_]+)_libretro/#).map { String($0.1) }
                let icon = (obj["icon"] as? String)?.replacingOccurrences(of: "/mnt/SDCARD/", with: "")
                out.append(EmulatorConfig(dir: d, kind: kind, label: obj["label"] as? String ?? d.lastPathComponent,
                                          romFolder: parts[0], extensions: Set(ext).subtracting(["miyoocmd"]), core: core,
                                          iconPath: icon))
            }
        }
        return out
    }

    static func listBios(_ root: URL) -> Set<String> {
        let base = root.appendingPathComponent("BIOS")
        guard let e = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil, options: .skipsHiddenFiles) else { return [] }
        var s = Set<String>()
        for case let u as URL in e {
            let rel = u.path.replacingOccurrences(of: base.path + "/", with: "")
            if rel.components(separatedBy: "/").count <= 2 { s.insert(rel.lowercased()) } else { e.skipDescendants() }
        }
        return s
    }

    static func readArcadeNames(_ root: URL) -> [String: String] {
        let dat = root.appendingPathComponent("BIOS/FinalBurn Neo (ClrMame Pro XML, Arcade only).dat")
        guard let s = try? String(contentsOf: dat, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for m in s.matches(of: #/<game name="([^"]+)"[^>]*>\s*<description>([^<]+)<\/description>/#) {
            out[String(m.1)] = String(m.2).replacingOccurrences(of: "&amp;", with: "&")
        }
        return out
    }

    static func readThemes(_ root: URL) -> [ThemeInfo] {
        let base = root.appendingPathComponent("Themes")
        return ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [])
            .filter { isDir($0) && FileManager.default.fileExists(atPath: $0.appendingPathComponent("config.json").path) }
            .map { ThemeInfo(name: $0.lastPathComponent, url: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func readActiveTheme(_ root: URL) -> String? {
        let dir = root.appendingPathComponent(".tmp_update/config/system")
        let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "json" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
        for f in files {
            if let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let t = o["theme"] as? String {
                return t.replacingOccurrences(of: "/mnt/SDCARD/", with: "").trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            }
        }
        return nil
    }

    static func readFavorites(_ root: URL) -> Set<String> {
        let f = root.appendingPathComponent("Roms/favourite.json")
        guard let s = try? String(contentsOf: f, encoding: .utf8) else { return [] }
        var out = Set<String>()
        for line in s.split(separator: "\n") {
            guard let d = line.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let p = o["rompath"] as? String, let r = p.range(of: "/Roms/") else { continue }
            out.insert(String(p[r.upperBound...]))
        }
        return out
    }

    static func readPackages(_ root: URL) -> [PackageInfo] {
        let fm = FileManager.default
        var out: [PackageInfo] = []
        for kind in ["Emu", "RApp"] {
            let base = root.appendingPathComponent("App/PackageManager/data/\(kind)")
            for p in (try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)) ?? [] {
                var targets: [String] = []
                for top in ["Emu", "RApp"] {
                    let t = p.appendingPathComponent(top)
                    for sub in (try? fm.contentsOfDirectory(atPath: t.path)) ?? [] where !sub.hasPrefix(".") {
                        targets.append("\(top)/\(sub)")
                    }
                }
                guard !targets.isEmpty else { continue }
                out.append(PackageInfo(name: p.lastPathComponent, kind: kind, url: p, targets: targets))
            }
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

// MARK: - Writing

enum CardWriter {
    static func writeFavorites(root: URL, games: [Game], emulators: [EmulatorConfig]) throws {
        let lines: [String] = games.compactMap { g in
            guard let emu = emulators.first(where: { $0.romFolder == g.system && $0.kind == "Emu" })
                    ?? emulators.first(where: { $0.romFolder == g.system }) else { return nil }
            let e = "/mnt/SDCARD/\(emu.kind)/\(emu.dir.lastPathComponent)"
            let obj: [String: Any] = [
                "label": g.title,
                "rompath": "\(e)/../../Roms/\(g.relPath)",
                "imgpath": "\(e)/../../Roms/\(g.system)/Imgs/\(g.stem).png",
                "launch": "\(e)/launch.sh",
                "type": 5,
            ]
            guard let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]) else { return nil }
            return String(decoding: d, as: UTF8.self)
        }
        let s = lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n"
        try s.write(to: root.appendingPathComponent("Roms/favourite.json"), atomically: false, encoding: .utf8)
    }

    /// Onion caches each list in <System>_cache6.db; removing it makes the device rescan.
    static func invalidateCache(root: URL, system: String) {
        let dir = root.appendingPathComponent("Roms/\(system)")
        for f in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where f.hasSuffix("_cache6.db") {
            try? FileManager.default.removeItem(at: dir.appendingPathComponent(f))
        }
    }

    /// Remove macOS AppleDouble files ("._name") that Finder-style copies leave on FAT volumes.
    static func removeAppleDouble(near url: URL) {
        let ad = url.deletingLastPathComponent().appendingPathComponent("._" + url.lastPathComponent)
        try? FileManager.default.removeItem(at: ad)
    }

    static func unlockAndRemove(_ url: URL) throws {
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) {
            for case let f as URL in e { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: f.path) }
        }
        try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: url.path)
        try FileManager.default.removeItem(at: url)
    }
}
