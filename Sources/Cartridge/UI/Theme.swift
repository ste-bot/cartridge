import AppKit
import SwiftUI

// MARK: - Tokens
//
// Palette is taken from handheld hardware rather than "app" colours:
// paper  – pale grey plastic of a pocket console (cool, not cream)
// ink    – the near-black of printed labels
// lcd    – the olive of an unlit reflective screen
// button – the magenta-maroon of the A/B buttons; the only accent

enum Palette {
    static let paper = dynamic(0xE2E4DE, 0x171918)
    static let panel = dynamic(0xEDEFEA, 0x1F2220)
    static let ink = dynamic(0x1C1F23, 0xDCE0D7)
    static let mute = dynamic(0x666B66, 0x8E948C)
    static let rule = dynamic(0xC2C6BE, 0x323632)
    static let lcd = dynamic(0x9DAA88, 0x56664A)
    static let lcdInk = dynamic(0x2F3A28, 0xC9D6B8)
    static let button = dynamic(0x8E2C69, 0xC65C9F)
    static let warn = dynamic(0xA6532A, 0xD98A5B)

    static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { a in
            let h = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255,
                           blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        })
    }
}

enum Fonts {
    /// Geist Pixel: titles, numbers and anything that would be printed on a cartridge label. Never body text.
    static func pixel(_ size: CGFloat) -> Font { .custom("GeistPixel-Square", size: size) }
    static func body(_ size: CGFloat = 13) -> Font { .custom("Geist-Regular", size: size) }
    static func medium(_ size: CGFloat = 13) -> Font { .custom("Geist-Medium", size: size) }
    static func strong(_ size: CGFloat = 13) -> Font { .custom("Geist-SemiBold", size: size) }
    static func mono(_ size: CGFloat = 11) -> Font { .custom("GeistMono-Regular", size: size) }

    static func registerFonts() {
        let candidates = [Bundle.main.resourceURL?.appendingPathComponent("Fonts"),
                          URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/Fonts")]
        for dir in candidates.compactMap({ $0 }) {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            let fonts = files.filter { $0.pathExtension == "ttf" }
            guard !fonts.isEmpty else { continue }
            CTFontManagerRegisterFontURLs(fonts as CFArray, .process, true, nil)
            return
        }
    }
}

// MARK: - Ordered dither (the signature)
//
// Every "fill" in the app — storage, ratings, placeholders — is a 4×4 Bayer dither
// between two colours on a hard pixel grid instead of a gradient or a flat tint.

private let bayer: [[Double]] = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]].map { $0.map { ($0 + 0.5) / 16 } }

struct Dither: View {
    /// Density at a position 0...1 along the ramp axis. Constant for flat fills.
    var density: (Double) -> Double
    var ink: Color
    var pixel: CGFloat = 2
    var vertical = false           // ramp runs bottom (0) → top (1)

    init(_ density: Double, ink: Color, pixel: CGFloat = 2) {
        self.density = { _ in density }; self.ink = ink; self.pixel = pixel
    }

    init(ramp from: Double, to: Double, ink: Color, pixel: CGFloat = 2, vertical: Bool = false) {
        self.density = { from + (to - from) * $0 }; self.ink = ink; self.pixel = pixel; self.vertical = vertical
    }

    var body: some View {
        Canvas { ctx, size in
            let cols = Int(ceil(size.width / pixel)), rows = Int(ceil(size.height / pixel))
            var path = Path()
            for x in 0..<cols {
                for y in 0..<rows {
                    let t = vertical ? (rows > 1 ? 1 - Double(y) / Double(rows - 1) : 0)
                                     : (cols > 1 ? Double(x) / Double(cols - 1) : 0)
                    guard bayer[y & 3][x & 3] < density(t) else { continue }
                    path.addRect(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel))
                }
            }
            ctx.fill(path, with: .color(ink))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Meters

/// A segmented meter like a handheld battery gauge. The partially-filled segment is dithered.
struct SegmentMeter: View {
    var value: Double              // 0...1
    var segments = 10
    var color: Color = Palette.ink
    var height: CGFloat = 10

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                let fill = min(1, max(0, value * Double(segments) - Double(i)))
                ZStack {
                    Rectangle().fill(Palette.rule.opacity(0.6))
                    if fill >= 0.999 { Rectangle().fill(color) }
                    else if fill > 0 { Dither(fill, ink: color, pixel: 1.5) }
                }
                .frame(height: height)
            }
        }
        .accessibilityElement()
        .accessibilityValue("\(Int(value * 100)) percent")
    }
}

struct RatingView: View {
    var meta: GameMeta?
    var compact = false

    var body: some View {
        if let r = meta?.rating, let n = meta?.ratingCount, n > 0 {
            HStack(spacing: 8) {
                SegmentMeter(value: r / 5, segments: 5, color: Palette.ink, height: compact ? 6 : 10)
                    .frame(width: compact ? 44 : 90)
                Text(String(format: "%.1f", r)).font(Fonts.pixel(compact ? 12 : 18)).foregroundStyle(Palette.ink).fixedSize()
                if !compact { Text("\(n.formatted()) ratings").font(Fonts.mono(11)).foregroundStyle(Palette.mute) }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Rated \(String(format: "%.1f", r)) out of 5 from \(n) ratings")
        } else if !compact {
            Text("No community rating").font(Fonts.mono(11)).foregroundStyle(Palette.mute)
        }
    }
}

// MARK: - Glyphs

/// Pixel cartridge silhouette in a system's colour, used as the system swatch everywhere.
struct CartridgeGlyph: View {
    var color: Color
    var size: CGFloat = 14

    var body: some View {
        Canvas { ctx, s in
            let u = s.width / 7
            var body = Path()
            body.addRect(CGRect(x: 0, y: u, width: 7 * u, height: 7 * u))
            body.addRect(CGRect(x: 0, y: 0, width: 6 * u, height: u))
            ctx.fill(body, with: .color(color))
            ctx.fill(Path(CGRect(x: u, y: 2 * u, width: 5 * u, height: 3 * u)), with: .color(.white.opacity(0.55)))
            for i in 0..<3 {
                ctx.fill(Path(CGRect(x: CGFloat(1 + 2 * i) * u, y: 7 * u, width: u, height: u)), with: .color(.black.opacity(0.25)))
            }
        }
        .frame(width: size, height: size * 8 / 7)
        .accessibilityHidden(true)
    }
}

/// The SD card itself, filled from the bottom by a dither that thickens with how full it is.
struct SDCardGraphic: View {
    var used: Double

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height, notch = w * 0.22
            let outline = Path { p in
                p.move(to: .init(x: notch, y: 0)); p.addLine(to: .init(x: w, y: 0))
                p.addLine(to: .init(x: w, y: h)); p.addLine(to: .init(x: 0, y: h))
                p.addLine(to: .init(x: 0, y: notch)); p.closeSubpath()
            }
            ZStack(alignment: .bottom) {
                outline.fill(Palette.panel)
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Dither(ramp: 0.95, to: 0.3, ink: Palette.ink, pixel: 3, vertical: true)
                        .frame(width: w, height: h * used)
                }
                .clipShape(outline)
                HStack(spacing: w * 0.05) {
                    ForEach(0..<5, id: \.self) { _ in Rectangle().fill(Palette.lcd).frame(width: w * 0.09, height: h * 0.16) }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                .padding(.top, h * 0.06)
                .padding(.leading, notch * 0.5)
                outline.stroke(Palette.ink, lineWidth: 2)
            }
        }
        .aspectRatio(24 / 32, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Card \(Int(used * 100)) percent full")
    }
}

// MARK: - Shared pieces

struct Eyebrow: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(Fonts.mono(10)).tracking(1.2).foregroundStyle(Palette.mute)
    }
}

struct PixelButtonStyle: ButtonStyle {
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Fonts.medium(12))
            .padding(.horizontal, 12).padding(.vertical, 6)
            .foregroundStyle(prominent ? Palette.paper : Palette.ink)
            .background(prominent ? Palette.button : Palette.panel)
            .overlay(Rectangle().strokeBorder(prominent ? Palette.button : Palette.ink, lineWidth: 1))
            .offset(y: configuration.isPressed ? 1 : 0)
            .background(Rectangle().fill(Palette.ink.opacity(prominent ? 0.35 : 0.2)).offset(y: configuration.isPressed ? 1 : 2))
            .contentShape(Rectangle())
    }
}

struct Panel<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.panel)
            .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: 1))
    }
}

/// The system's real hardware icon from the card's Icons/Default pack; the cartridge glyph if there isn't one.
struct SystemIcon: View {
    @Environment(AppModel.self) private var model
    var folder: String
    var size: CGFloat = 18

    @State private var image: NSImage?

    var body: some View {
        let url = model.snapshot?.systemIcons[folder]
        Group {
            if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                CartridgeGlyph(color: SystemCatalog.info(for: folder).color, size: size * 0.7)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) {
            guard let url else { image = nil; return }
            image = await IconCache.shared.image(url)
        }
        .accessibilityHidden(true)
    }
}

actor IconCache {
    static let shared = IconCache()
    private var cache: [URL: NSImage] = [:]
    func image(_ url: URL) -> NSImage? {
        if let i = cache[url] { return i }
        let i = NSImage(contentsOf: url)
        cache[url] = i
        return i
    }
}

/// Thread-safe in-memory image cache that views read synchronously while rendering,
/// so a cached cover shows in the same frame its game is selected.
final class ImageMemory: @unchecked Sendable {
    static let shared = ImageMemory()
    private let cache = NSCache<NSURL, NSImage>()
    subscript(url: URL) -> NSImage? {
        get { cache.object(forKey: url as NSURL) }
        set { if let newValue { cache.setObject(newValue, forKey: url as NSURL) } }
    }
}

/// Covers from LaunchBox, cached in memory and on disk in ~/Library/Caches/Cartridge.
actor RemoteImages {
    static let shared = RemoteImages()
    private let dir: URL = {
        let u = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Cartridge/covers")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }()

    func image(for url: URL) async -> NSImage? {
        if let m = ImageMemory.shared[url] { return m }
        let file = dir.appendingPathComponent(url.lastPathComponent)
        if let d = try? Data(contentsOf: file), let img = NSImage(data: d) { ImageMemory.shared[url] = img; return img }
        guard let (d, resp) = try? await URLSession.shared.data(from: url),
              (resp as? HTTPURLResponse)?.statusCode == 200, let img = NSImage(data: d) else { return nil }
        try? d.write(to: file)
        ImageMemory.shared[url] = img
        return img
    }
}

/// Box art for a game: the card's own image, then LaunchBox, then a dithered label.
struct ArtView: View {
    var game: Game
    var meta: GameMeta?
    @State private var local: NSImage?
    @State private var loadedKey: String?

    /// The card's own image first, then LaunchBox.
    private var sourceURL: URL? { game.artURL ?? meta?.boxArtURL }
    private var key: String { sourceURL?.absoluteString ?? "none:\(game.id)" }

    var body: some View {
        // Only trust `local` if it was loaded for the current game; otherwise use the
        // in-memory cache synchronously. Never shows another game's cover.
        let shown = (loadedKey == key ? local : nil) ?? sourceURL.flatMap { ImageMemory.shared[$0] }
        ZStack {
            Rectangle().fill(Palette.paper)
            if let shown {
                Image(nsImage: shown).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
            } else { placeholder }
        }
        .clipped()
        .task(id: key) {
            guard let u = sourceURL else { local = nil; loadedKey = key; return }
            let img: NSImage?
            if u.isFileURL {
                img = await Task.detached { NSImage(contentsOf: u) }.value
                if let img { ImageMemory.shared[u] = img }
            } else {
                img = await RemoteImages.shared.image(for: u)
            }
            local = img
            loadedKey = key
        }
    }

    var placeholder: some View {
        let info = SystemCatalog.info(for: game.system)
        return ZStack {
            Dither(0.28, ink: info.color, pixel: 3)
            Text(initials).font(Fonts.pixel(28)).foregroundStyle(info.color)
                .padding(6).background(Palette.paper)
        }
    }

    var initials: String {
        let words = game.title.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2)
        return words.map { String($0.prefix(1)).uppercased() }.joined()
    }
}
