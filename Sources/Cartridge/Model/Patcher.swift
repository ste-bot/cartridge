import AppKit
import Foundation

// MARK: - Patch formats

enum PatchFormat: String {
    case bps = "BPS", ups = "UPS", ips = "IPS"

    static let fileExtensions: Set<String> = ["bps", "ups", "ips"]
    /// Formats hacks are sometimes shipped in that Cartridge can't apply.
    static let unsupportedExtensions: Set<String> = ["xdelta", "xdelta3", "vcdiff", "ppf", "aps"]
}

/// What a patch says about itself before it is applied. BPS and UPS name the exact base ROM they need
/// (size and CRC32); IPS doesn't, so its base has to be picked by hand.
struct PatchHeader: Equatable {
    var format: PatchFormat
    var sourceSize: Int?
    var sourceCRC: UInt32?
    var targetSize: Int?
    var targetCRC: UInt32?
}

struct PatchError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

enum Patcher {
    static func header(of p: [UInt8]) throws -> PatchHeader {
        if p.starts(with: Array("BPS1".utf8)) || p.starts(with: Array("UPS1".utf8)) {
            guard p.count > 16 else { throw PatchError("The patch file is too short.") }
            var pos = 4
            let src = try vint(p, &pos), dst = try vint(p, &pos)
            // Both formats end with source CRC, target CRC, patch CRC.
            return PatchHeader(format: p[0] == UInt8(ascii: "B") ? .bps : .ups, sourceSize: src, sourceCRC: le32(p, p.count - 12),
                               targetSize: dst, targetCRC: le32(p, p.count - 8))
        }
        if p.starts(with: Array("PATCH".utf8)) { return PatchHeader(format: .ips) }
        throw PatchError("This isn't a BPS, UPS or IPS patch.")
    }

    /// Applies a patch and checks every checksum it carries. Throws rather than return a ROM that doesn't match.
    static func apply(_ patch: [UInt8], to source: [UInt8]) throws -> [UInt8] {
        let h = try header(of: patch)
        if let cs = h.sourceCRC, let ss = h.sourceSize, source.count != ss || crc32(source) != cs {
            throw PatchError("That base ROM isn't the one this patch was made for (needs CRC \(hex(cs)), got \(hex(crc32(source)))).")
        }
        let out: [UInt8]
        switch h.format {
        case .bps: out = try applyBPS(patch, source)
        case .ups: out = try applyUPS(patch, source)
        case .ips: out = try applyIPS(patch, source)
        }
        if let ct = h.targetCRC, crc32(out) != ct {
            throw PatchError("The patched ROM failed its checksum (\(hex(crc32(out))), expected \(hex(ct))). The patch may be damaged.")
        }
        return out
    }

    private static func applyBPS(_ p: [UInt8], _ src: [UInt8]) throws -> [UInt8] {
        // Some tools leave the patch's own CRC as 0; the target CRC check still covers the result.
        let pc = le32(p, p.count - 4)
        if pc != 0, crc32(p[0..<(p.count - 4)]) != pc { throw PatchError("The patch file is damaged (its checksum doesn't match).") }
        var pos = 4
        _ = try vint(p, &pos)
        let dstSize = try vint(p, &pos)
        pos += try vint(p, &pos)                       // skip metadata
        var out = [UInt8](repeating: 0, count: dstSize)
        var o = 0, srcRel = 0, dstRel = 0
        let end = p.count - 12
        while pos < end {
            let data = try vint(p, &pos)
            let len = (data >> 2) + 1
            guard o + len <= dstSize else { throw PatchError("The patch writes past the end of the ROM.") }
            switch data & 3 {
            case 0:
                guard o + len <= src.count else { throw PatchError("The patch reads past the end of the base ROM.") }
                out.replaceSubrange(o..<(o + len), with: src[o..<(o + len)])
            case 1:
                guard pos + len <= end else { throw PatchError("The patch file is cut short.") }
                out.replaceSubrange(o..<(o + len), with: p[pos..<(pos + len)]); pos += len
            case 2:
                srcRel += signed(try vint(p, &pos))
                guard srcRel >= 0, srcRel + len <= src.count else { throw PatchError("The patch reads outside the base ROM.") }
                out.replaceSubrange(o..<(o + len), with: src[srcRel..<(srcRel + len)]); srcRel += len
            default:
                dstRel += signed(try vint(p, &pos))
                guard dstRel >= 0, dstRel < o else { throw PatchError("The patch copies from an invalid position.") }
                // May overlap the bytes it's writing (run-length fills), so copy one byte at a time.
                for _ in 0..<len { out[o] = out[dstRel]; o += 1; dstRel += 1 }
                continue
            }
            o += len
        }
        return out
    }

    private static func applyUPS(_ p: [UInt8], _ src: [UInt8]) throws -> [UInt8] {
        var pos = 4
        _ = try vint(p, &pos)
        let dstSize = try vint(p, &pos)
        var out = Array(src.prefix(dstSize))
        if out.count < dstSize { out += [UInt8](repeating: 0, count: dstSize - out.count) }
        var o = 0
        let end = p.count - 12
        while pos < end {
            o += try vint(p, &pos)
            while pos < end {
                let b = p[pos]; pos += 1
                if b == 0 { o += 1; break }
                guard o < dstSize else { throw PatchError("The patch writes past the end of the ROM.") }
                out[o] ^= b; o += 1
            }
        }
        return out
    }

    private static func applyIPS(_ p: [UInt8], _ src: [UInt8]) throws -> [UInt8] {
        var out = src
        var pos = 5
        func need(_ n: Int) throws { if pos + n > p.count { throw PatchError("The patch file is cut short.") } }
        while true {
            try need(3)
            if p[pos] == 0x45, p[pos + 1] == 0x4F, p[pos + 2] == 0x46 {        // "EOF"
                pos += 3
                if pos + 3 <= p.count {                                         // optional truncate-to size
                    let size = Int(p[pos]) << 16 | Int(p[pos + 1]) << 8 | Int(p[pos + 2])
                    if size < out.count { out.removeSubrange(size...) }
                }
                return out
            }
            let off = Int(p[pos]) << 16 | Int(p[pos + 1]) << 8 | Int(p[pos + 2]); pos += 3
            try need(2)
            var len = Int(p[pos]) << 8 | Int(p[pos + 1]); pos += 2
            var bytes: ArraySlice<UInt8>
            if len == 0 {                                                       // run-length record
                try need(3)
                len = Int(p[pos]) << 8 | Int(p[pos + 1])
                bytes = ArraySlice(repeating: p[pos + 2], count: len); pos += 3
            } else {
                try need(len)
                bytes = p[pos..<(pos + len)]; pos += len
            }
            if off + len > out.count { out += [UInt8](repeating: 0, count: off + len - out.count) }
            out.replaceSubrange(off..<(off + len), with: bytes)
        }
    }

    // MARK: Helpers

    private static func vint(_ d: [UInt8], _ p: inout Int) throws -> Int {
        var n = 0, s = 1
        while true {
            guard p < d.count, s < 1 << 56 else { throw PatchError("The patch file is damaged.") }
            let x = Int(d[p]); p += 1
            n += (x & 0x7f) * s
            if x & 0x80 != 0 { return n }
            s <<= 7; n += s
        }
    }

    private static func signed(_ v: Int) -> Int { v & 1 == 1 ? -(v >> 1) : v >> 1 }
    private static func le32(_ d: [UInt8], _ i: Int) -> UInt32 {
        UInt32(d[i]) | UInt32(d[i + 1]) << 8 | UInt32(d[i + 2]) << 16 | UInt32(d[i + 3]) << 24
    }
    static func hex(_ v: UInt32) -> String { String(format: "%08X", v) }

    private static let crcTable: [UInt32] = (0..<256).map { i in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32<C: Collection>(_ bytes: C) -> UInt32 where C.Element == UInt8 {
        var c: UInt32 = 0xFFFFFFFF
        crcTable.withUnsafeBufferPointer { t in
            for b in bytes { c = t[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFFFFFF
    }

    static func crc32(of url: URL) -> UInt32? {
        guard let d = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        return d.withUnsafeBytes { crc32($0.bindMemory(to: UInt8.self)) }
    }
}

// MARK: - Base ROMs

/// Clean dumps that ROM hacks are commonly built on, so Cartridge can name the base it needs.
enum KnownBase {
    static let names: [UInt32: String] = [
        0x1F1C08FB: "Pokémon Emerald (USA, Europe)",
        0xDD88761C: "Pokémon FireRed (USA) 1.0",
        0x84EE4776: "Pokémon FireRed (USA) 1.1",
        0xD69C96CC: "Pokémon LeafGreen (USA) 1.0",
        0xF0815EE7: "Pokémon Ruby (USA) 1.0",
        0x554DEDC4: "Pokémon Sapphire (USA) 1.0",
    ]

    static func name(_ crc: UInt32?) -> String? { crc.flatMap { names[$0] } }

    /// Folders Cartridge looks in for a base ROM: ones the user picked a base from before, then Downloads.
    static var searchFolders: [URL] {
        let saved = (UserDefaults.standard.stringArray(forKey: "baseROMFolders") ?? []).map { URL(fileURLWithPath: $0) }
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)
        return saved + downloads
    }

    static func remember(folderOf url: URL) {
        let dir = url.deletingLastPathComponent().path
        var saved = UserDefaults.standard.stringArray(forKey: "baseROMFolders") ?? []
        saved.removeAll { $0 == dir }
        saved.insert(dir, at: 0)
        UserDefaults.standard.set(Array(saved.prefix(5)), forKey: "baseROMFolders")
    }

    /// Finds a file with exactly this size and CRC32. Only same-size files are read, so this stays quick.
    static func find(size: Int, crc: UInt32, in folders: [URL]) -> URL? {
        let fm = FileManager.default
        for folder in folders {
            guard let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                if e.level > 4 { e.skipDescendants(); continue }
                guard let v = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                      v.isRegularFile == true, v.fileSize == size else { continue }
                if Patcher.crc32(of: url) == crc { return url }
            }
        }
        return nil
    }
}

// MARK: - GitHub releases

struct GitHubRelease: Decodable {
    struct Asset: Decodable, Hashable {
        let name: String
        let size: Int
        let browser_download_url: URL
    }
    let tag_name: String
    let name: String?
    let body: String?
    let html_url: URL
    let assets: [Asset]

    /// The first image in the release notes, used as box art (hacks often lead with their title screen).
    var imageURL: URL? {
        guard let body else { return nil }
        let patterns = [#/<img[^>]*src="(https://[^"]+)"/#, #/!\[[^\]]*\]\((https://[^)\s]+)\)/#]
        for p in patterns {
            if let m = body.firstMatch(of: p), let u = URL(string: String(m.1)) { return u }
        }
        return nil
    }
}

/// Where a patch came from, so the game can be updated later.
struct PatchSource: Codable, Hashable {
    var link: String?         // the GitHub link the user gave; nil for a local file
    var repo: String?         // "owner/name"
    var tag: String?
    var patchName: String
    var baseCRC: String?
    var patched: Date
}

enum GitHubPatches {
    struct Resolved {
        var repo: String
        var release: GitHubRelease
        var patches: [GitHubRelease.Asset]   // directly applicable assets
        var zips: [GitHubRelease.Asset]      // archives that may hold a patch
        var preferred: String?               // asset named in the link, if any
    }

    /// Accepts a repo, release, tag or asset link on github.com and finds the patch files in that release.
    static func resolve(_ link: String) async throws -> Resolved {
        var s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.contains("://") { s = "https://" + s }
        guard let url = URL(string: s), let host = url.host(), host.hasSuffix("github.com") else {
            throw PatchError("Paste a GitHub link, like github.com/owner/repo or a link to one of its releases.")
        }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 2 else { throw PatchError("That link doesn't point to a repository.") }
        let repo = "\(parts[0])/\(parts[1].replacingOccurrences(of: ".git", with: ""))"
        var tag: String?, preferred: String?
        if parts.count >= 5, parts[2] == "releases", parts[3] == "tag" { tag = parts[4...].joined(separator: "/") }
        if parts.count >= 6, parts[2] == "releases", parts[3] == "download" { tag = parts[4]; preferred = parts[5] }

        let release: GitHubRelease
        if let tag {
            release = try await fetch("repos/\(repo)/releases/tags/\(tag)")
        } else if let latest: GitHubRelease = try? await fetch("repos/\(repo)/releases/latest") {
            release = latest
        } else {
            // No "latest" when every release is a pre-release; take the newest of any kind.
            let all: [GitHubRelease] = try await fetch("repos/\(repo)/releases?per_page=1")
            guard let first = all.first else { throw PatchError("\(repo) has no releases to patch from.") }
            release = first
        }
        let ext = { (a: GitHubRelease.Asset) in (a.name as NSString).pathExtension.lowercased() }
        let patches = release.assets.filter { PatchFormat.fileExtensions.contains(ext($0)) }
        let zips = release.assets.filter { ext($0) == "zip" || ext($0) == "7z" }
        if patches.isEmpty && zips.isEmpty {
            if let odd = release.assets.first(where: { PatchFormat.unsupportedExtensions.contains(ext($0)) }) {
                throw PatchError("\(release.tag_name) ships “\(odd.name)”. Cartridge applies BPS, UPS and IPS patches, not .\(ext(odd)).")
            }
            throw PatchError("Release \(release.tag_name) of \(repo) has no patch file attached.")
        }
        return Resolved(repo: repo, release: release, patches: patches, zips: zips, preferred: preferred)
    }

    private static func fetch<T: Decodable>(_ path: String) async throws -> T {
        var req = URLRequest(url: URL(string: "https://api.github.com/" + path)!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (d, r) = try await URLSession.shared.data(for: req)
        let code = (r as? HTTPURLResponse)?.statusCode ?? 0
        if code == 404 { throw PatchError("GitHub couldn't find that repository or release. Private repos aren't supported.") }
        if code == 403 { throw PatchError("GitHub's rate limit was hit. Try again in a few minutes.") }
        guard code == 200 else { throw PatchError("GitHub answered with an error (\(code)).") }
        return try JSONDecoder().decode(T.self, from: d)
    }

    /// Downloads an asset into a fresh temporary folder. Archives are unpacked and searched for patches.
    static func download(_ asset: GitHubRelease.Asset) async throws -> [URL] {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("cartridge-patch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let (tmp, _) = try await URLSession.shared.download(from: asset.browser_download_url)
        let file = work.appendingPathComponent(asset.name)
        try FileManager.default.moveItem(at: tmp, to: file)
        let ext = file.pathExtension.lowercased()
        guard ext == "zip" else {
            if ext == "7z" { throw PatchError("“\(asset.name)” is a 7z archive. Unpack it, then drop the patch file in.") }
            return [file]
        }
        let out = work.appendingPathComponent("x")
        try await Shell.run("/usr/bin/ditto", ["-x", "-k", file.path, out.path])
        return patchFiles(in: out)
    }

    static func patchFiles(in folder: URL) -> [URL] {
        let e = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        var found: [URL] = []
        while let u = e?.nextObject() as? URL {
            if !u.path.contains("__MACOSX"), PatchFormat.fileExtensions.contains(u.pathExtension.lowercased()) { found.append(u) }
        }
        return found.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

// MARK: - Names and art

@MainActor
enum PatchNaming {
    /// A file name without the version, so an update lands on the same file and keeps its save.
    /// "HnS-Legends" on an Emerald base -> "Pokemon HnS Legends"; "HnS_Legends_v0_21b.bps" -> "HnS Legends".
    static func suggestedName(repo: String?, patchFile: String, baseCRC: UInt32?) -> String {
        var name = repo.map { String($0.split(separator: "/").last ?? "") } ?? (patchFile as NSString).deletingPathExtension
        name = name.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
        name = name.replacing(#/(?i)\b(v|ver\.?)\s?\d+([._]\d+)*[a-z]?\b/#, with: "")   // "v2.0.5" anywhere
        name = name.replacing(#/(?i)[\s.]*(\(|\[)?(v|ver\.?|version|m)?\s?\d+([.\s]\d+)*[a-z]?(\)|\])?\s*$/#, with: "")
        name = name.split(separator: " ").joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if name.isEmpty { name = "Patched ROM" }
        if let base = KnownBase.name(baseCRC), base.hasPrefix("Pokémon"), !name.lowercased().contains("pok") {
            name = "Pokemon " + name
        }
        return AppModel.safeFileName(name)
    }
}

extension NSImage {
    /// A centered square crop scaled to `side`, for Onion's square box-art slot.
    func squarePNG(side: CGFloat) -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let w = cg.width, h = cg.height, s = min(w, h)
        guard let crop = cg.cropping(to: CGRect(x: (w - s) / 2, y: (h - s) / 2, width: s, height: s)) else { return nil }
        let px = Int(side)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        NSGraphicsContext.current?.cgContext.draw(crop, in: CGRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }
}
