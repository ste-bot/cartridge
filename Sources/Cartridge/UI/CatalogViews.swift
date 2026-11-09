import SwiftUI

struct CatalogGrid: View {
    @Environment(AppModel.self) private var model
    var entries: [GameMeta]
    var scope: LibraryScope

    var body: some View {
        let owned = model.owned
        LazyVGrid(columns: LibraryView.columns, spacing: 22) {
            ForEach(entries, id: \.id) { e in
                CatalogTile(entry: e, onCard: owned[e.id] != nil, selected: model.selectedCatalog == e.id,
                            showSystem: { if case .system = scope { false } else { true } }())
                    .onTapGesture { model.selectedCatalog = e.id }
            }
        }
    }
}

/// A LaunchBox cover with a dithered placeholder while it loads (or if there isn't one).
struct CoverView: View {
    var entry: GameMeta
    @State private var image: NSImage?

    var body: some View {
        let shown = image ?? entry.boxArtURL.flatMap { ImageMemory.shared[$0] }
        ZStack {
            Rectangle().fill(Palette.paper)
            if let shown {
                Image(nsImage: shown).resizable().aspectRatio(contentMode: .fit)
            } else {
                Dither(0.22, ink: Palette.mute, pixel: 3)
                Text(initials).font(Fonts.pixel(26)).foregroundStyle(Palette.mute).padding(6).background(Palette.paper)
            }
        }
        .clipped()
        .task(id: entry.id) {
            image = nil
            if let u = entry.boxArtURL { image = await RemoteImages.shared.image(for: u) }
        }
    }

    var initials: String {
        entry.name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).prefix(2).map { String($0.prefix(1)).uppercased() }.joined()
    }
}

struct CatalogTile: View {
    var entry: GameMeta
    var onCard: Bool
    var selected: Bool
    var showSystem: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            CoverView(entry: entry)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .bottomLeading) {
                    if onCard {
                        Text("ON CARD").font(Fonts.mono(9)).tracking(0.8)
                            .foregroundStyle(Palette.paper)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Palette.ink)
                            .padding(6)
                    }
                }
                .overlay(Rectangle().strokeBorder(selected ? Palette.ink : (onCard ? Palette.ink.opacity(0.6) : Palette.rule),
                                                  lineWidth: selected ? 2 : 1))
            Text(entry.name).font(Fonts.medium(12)).foregroundStyle(Palette.ink).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(caption).font(Fonts.mono(10)).foregroundStyle(Palette.mute).lineLimit(1)
                Spacer(minLength: 0)
                RatingView(meta: entry, compact: true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(entry.name + (onCard ? ", on card" : ""))
        .accessibilityAddTraits(.isButton)
    }

    var caption: String {
        let year = entry.year.map(String.init) ?? "—"
        return showSystem ? "\(year) · \(entry.platform.replacingOccurrences(of: "Nintendo ", with: ""))" : year
    }
}

struct CatalogDetail: View {
    @Environment(AppModel.self) private var model
    var entry: GameMeta
    var scope: LibraryScope

    var body: some View {
        let game = model.owned[entry.id]
        let folder = model.folder(for: entry, scope: scope)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CoverView(entry: entry)
                    .frame(maxWidth: .infinity).frame(height: 260)
                    .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: 1))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        if let folder { SystemIcon(folder: folder, size: 16) }
                        Eyebrow(text: entry.platform + (entry.year.map { " · \($0)" } ?? ""))
                    }
                    Text(entry.name).font(Fonts.pixel(24)).foregroundStyle(Palette.ink).fixedSize(horizontal: false, vertical: true)
                }
                RatingView(meta: entry)

                if let game {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("On your card").font(Fonts.medium(13))
                        Text("Roms/\(game.relPath)").font(Fonts.mono(11)).foregroundStyle(Palette.mute).lineLimit(2)
                        Button("Show in my games") {
                            model.libraryMode = .mine
                            model.selectedCatalog = nil
                            model.selectedGame = game.id
                        }
                        .buttonStyle(PixelButtonStyle())
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 1))
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Not on your card").font(Fonts.medium(13))
                        Text("Have this game as a file, such as a dump of your own cartridge? Cartridge saves it to "
                             + "Roms/\(folder ?? "?") as “\(AppModel.safeFileName(entry.name))” so its cover and details match.")
                            .font(Fonts.body(12)).foregroundStyle(Palette.mute).fixedSize(horizontal: false, vertical: true)
                        Button("Add from file…") { model.addFromFile(for: entry, scope: scope) }
                            .buttonStyle(PixelButtonStyle(prominent: true))
                            .disabled(model.activity != nil || folder == nil)
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Palette.panel)
                    .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: 1))
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let g = entry.genres { LabeledRow(label: "Genre", value: g.replacingOccurrences(of: "; ", with: ", ")) }
                    if let d = entry.developer { LabeledRow(label: "Developer", value: d) }
                    if let p = entry.publisher, p != entry.developer { LabeledRow(label: "Publisher", value: p) }
                    if let p = entry.players { LabeledRow(label: "Players", value: "\(p)") }
                }
                if let o = entry.overview {
                    Text(o).font(Fonts.body(12.5)).foregroundStyle(Palette.ink).lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 14) {
                    if let u = entry.launchBoxURL { Link("Reviews on LaunchBox", destination: u) }
                    if let w = entry.wikipedia, let u = URL(string: w) { Link("Wikipedia", destination: u) }
                    if let v = entry.video, let u = URL(string: v) { Link("Video", destination: u) }
                }
                .font(Fonts.body(12))
            }
            .padding(20)
        }
        .background(Palette.paper)
    }
}
