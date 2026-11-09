import Foundation

enum Shell {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs a tool and returns stdout. Each stdout line is also passed to `onLine`.
    @discardableResult
    static func run(_ exe: String, _ args: [String], onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = args
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            let buffer = LockedBuffer()
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty else { return }
                let s = String(decoding: d, as: UTF8.self)
                buffer.append(s)
                if let onLine { s.split(separator: "\n").forEach { onLine(String($0)) } }
            }
            p.terminationHandler = { proc in
                out.fileHandleForReading.readabilityHandler = nil
                let rest = out.fileHandleForReading.readDataToEndOfFile()
                buffer.append(String(decoding: rest, as: UTF8.self))
                let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if proc.terminationStatus == 0 { cont.resume(returning: buffer.value) }
                else { cont.resume(throwing: Failure(message: e.isEmpty ? "\(exe) exited with \(proc.terminationStatus)" : e)) }
            }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }

    final class LockedBuffer: @unchecked Sendable {
        private var s = ""
        private let lock = NSLock()
        func append(_ x: String) { lock.lock(); s += x; lock.unlock() }
        var value: String { lock.lock(); defer { lock.unlock() }; return s }
    }
}

// MARK: - Onion releases

struct OnionRelease: Decodable, Identifiable, Hashable {
    struct Asset: Decodable, Hashable {
        let name: String
        let size: Int
        let browser_download_url: URL
    }
    var id: String { tag_name }
    let tag_name: String
    let name: String?
    let prerelease: Bool
    let published_at: Date?
    let html_url: URL
    let assets: [Asset]

    var version: String { tag_name.hasPrefix("v") ? String(tag_name.dropFirst()) : tag_name }
    var zip: Asset? { assets.first { $0.name.hasPrefix("Onion-") && $0.name.hasSuffix(".zip") } }
}

enum OnionUpdates {
    static func fetchReleases() async throws -> [OnionRelease] {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/OnionUI/Onion/releases?per_page=10")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (d, _) = try await URLSession.shared.data(for: req)
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode([OnionRelease].self, from: d)
    }

    /// "4.3.1-1" -> [4,3,1,1]; nil for non-version strings such as repack names.
    static func parse(_ v: String) -> [Int]? {
        guard let m = v.firstMatch(of: #/(\d+)\.(\d+)\.(\d+)(?:-(\d+))?/#) else { return nil }
        return [Int(m.1)!, Int(m.2)!, Int(m.3)!, Int(m.4 ?? "0") ?? 0]
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = parse(a), let y = parse(b) else { return true }
        return x.lexicographicallyPrecedes(y) == false && x != y
    }

    /// Downloads the release zip, unpacks it, and merges it onto the card. The device installs it on next boot.
    static func stage(_ release: OnionRelease, onto root: URL, progress: @escaping @Sendable (String) -> Void) async throws {
        guard let asset = release.zip else { throw Shell.Failure(message: "This release has no Onion zip.") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("onion-\(release.version)")
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        progress("Downloading \(asset.name)…")
        let (tmp, _) = try await URLSession.shared.download(from: asset.browser_download_url)
        progress("Unpacking…")
        try await Shell.run("/usr/bin/ditto", ["-x", "-k", tmp.path, work.appendingPathComponent("x").path])
        progress("Copying to card…")
        try await Shell.run("/usr/bin/rsync", ["-rt", work.appendingPathComponent("x").path + "/", root.path + "/"])
        try await Shell.run("/usr/bin/find", [root.path, "-path", root.appendingPathComponent(".Spotlight-V100").path, "-prune",
                                             "-o", "-name", "._*", "-type", "f", "-delete"])
        progress("Update copied. Boot the device to install.")
    }
}

// MARK: - Backup

enum Backup {
    static func run(card root: URL, to parent: URL, progress: @escaping @Sendable (Int) -> Void) async throws -> URL {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd-HHmm"
        let dest = parent.appendingPathComponent("Miyoo backup \(f.string(from: Date()))")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let counter = Counter()
        try await Shell.run("/usr/bin/rsync",
                            ["-rtv", "--exclude=.Spotlight-V100", "--exclude=.fseventsd", "--exclude=System Volume Information",
                             "--exclude=.Trashes", root.path + "/", dest.path + "/"],
                            onLine: { _ in progress(counter.increment()) })
        return dest
    }

    final class Counter: @unchecked Sendable {
        private var n = 0
        private let lock = NSLock()
        func increment() -> Int { lock.lock(); defer { lock.unlock() }; n += 1; return n }
    }
}

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
