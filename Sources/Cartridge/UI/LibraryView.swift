import SwiftUI
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    var scope: LibraryScope
    @State private var dropping = false
    @State private var importing = false

    var title: String {
        switch scope {
        case .all: "All games"
        case .favorites: "Favorites"
        case .system(let f): SystemCatalog.info(for: f).name
        }
    }

    /// The catalog only exists for real systems (and all of them), and needs the ratings database.
    var catalogAvailable: Bool {
        if case .favorites = scope { return false }
        return model.ratings != nil
    }

    var inCatalog: Bool { catalogAvailable && model.libraryMode == .catalog }

    /// The selection, resolved. A stale or unknown id leaves the inspector closed instead of empty.
    var pickedEntry: GameMeta? {
        guard inCatalog, let id = model.selectedCatalog else { return nil }
        return model.catalogEntries(scope).first { $0.id == id }
    }
    var pickedGame: Game? {
        guard !inCatalog, let id = model.selectedGame else { return nil }
        return model.games.first { $0.id == id }
    }

    static let columns = [GridItem(.adaptive(minimum: 150, maximum: 190), spacing: 18, alignment: .top)]

    var body: some View {
        @Bindable var model = model
        let scoped = model.scopedGames(scope)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header(count: scoped.count, bytes: scoped.reduce(0) { $0 + $1.size })
                if inCatalog {
                    let entries = model.visibleCatalog(scope)
                    FilterBar(scope: scope, shown: entries.count, catalog: true)
                    if entries.isEmpty { empty } else { CatalogGrid(entries: entries, scope: scope) }
                } else {
                    let games = model.visibleGames(scope: scope)
                    FilterBar(scope: scope, shown: games.count, catalog: false)
                    if model.noCoverOnly { CoverBanner(scope: scope) }
                    if games.isEmpty {
                        empty
                    } else {
                        LazyVGrid(columns: Self.columns, spacing: 22) {
                            ForEach(games) { g in
                                GameTile(game: g, meta: model.meta(for: g), selected: model.selectedGame == g.id,
                                         favorite: model.isFavorite(g))
                                    .onTapGesture { model.selectedGame = g.id }
                                    .contextMenu { GameMenu(game: g) }
                            }
                        }
                    }
                }
            }
            .padding(28)
        }
        .overlay {
            if dropping {
                ZStack {
                    Dither(0.18, ink: Palette.button, pixel: 3)
                    Text("Drop to add to the card").font(Fonts.pixel(26)).padding(12).background(Palette.paper)
                }
                .allowsHitTesting(false)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let forced: String? = { if case .system(let f) = scope { return f } else { return nil } }()
            Task { await model.addGames(urls, to: forced) }
            return true
        } isTargeted: { dropping = $0 }
        .searchable(text: $model.search, placement: .toolbar, prompt: "Search games")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { model.chooseGamesToAdd(scope: scope) } label: { Label("Add games", systemImage: "plus") }
                    .labelStyle(.titleAndIcon)
                    .help(addHelp)
                    .disabled(model.activity != nil)
            }
        }
        .inspector(isPresented: Binding(get: { pickedEntry != nil || pickedGame != nil },
                                        set: { if !$0 { model.selectedGame = nil; model.selectedCatalog = nil } })) {
            Group {
                if let e = pickedEntry {
                    CatalogDetail(entry: e, scope: scope)
                } else if let g = pickedGame {
                    GameDetail(game: g)
                }
            }
            .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
        }
    }

    var addHelp: String {
        if case .system(let f) = scope { return "Add ROM files to \(SystemCatalog.info(for: f).name)" }
        return "Add ROM files; each goes to its system by extension"
    }

    func header(count: Int, bytes: Int64) -> some View {
        @Bindable var model = model
        return HStack(alignment: .center, spacing: 14) {
            if case .system(let f) = scope { SystemIcon(folder: f, size: 44) }
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Fonts.pixel(32)).lineLimit(1).minimumScaleFactor(0.6)
                if inCatalog {
                    let c = model.catalogCoverage(scope)
                    HStack(spacing: 10) {
                        Text("\(c.have.formatted()) of \(c.total.formatted()) released games on card")
                            .font(Fonts.mono(12)).foregroundStyle(Palette.mute)
                        SegmentMeter(value: Double(c.have) / Double(max(1, c.total)), segments: 20, height: 6).frame(width: 160)
                    }
                } else {
                    Text("\(count.formatted()) games · \(bytes.bytes)").font(Fonts.mono(12)).foregroundStyle(Palette.mute)
                }
            }
            Spacer(minLength: 12)
            if catalogAvailable {
                Picker("Show", selection: $model.libraryMode) {
                    Text("On card").tag(LibraryMode.mine)
                    Text("Full catalog").tag(LibraryMode.catalog)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                .help("Switch between the games on your card and every game released for this system")
            }
        }
    }

    @ViewBuilder var empty: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch scope {
            case .favorites:
                Text("No favorites yet").font(Fonts.pixel(20))
                Text("Select a game and choose Add to Favorites. It shows up in the Favorites tab on the Miyoo too.")
            default:
                if model.filtersActive || !model.search.isEmpty || (inCatalog && model.availability != .all) {
                    Text("No games match").font(Fonts.pixel(20))
                    Button("Clear filters") { model.clearFilters(); model.search = ""; model.availability = .all }.buttonStyle(PixelButtonStyle())
                } else {
                    Text("Nothing here yet").font(Fonts.pixel(20))
                    Text("Drag ROM files onto this window, or use Add games. Cartridge puts each file in the right system folder by its extension.")
                }
            }
        }
        .font(Fonts.body(13)).foregroundStyle(Palette.mute)
        .frame(maxWidth: 440, alignment: .leading)
        .padding(.top, 30)
    }
}

/// Everything that narrows or orders the grid, in one row directly above it.
struct FilterBar: View {
    @Environment(AppModel.self) private var model
    var scope: LibraryScope
    var shown: Int
    var catalog: Bool

    /// Sort orders that make sense for catalog entries (no file size or date added).
    var sorts: [SortOrder] { catalog ? [.rating, .title, .year] : SortOrder.allCases }

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Menu {
                Picker("Sort", selection: $model.sort) {
                    ForEach(sorts) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                chipLabel("Sort: \((sorts.contains(model.sort) ? model.sort : .title).rawValue)", on: false, menu: true)
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()

            if catalog {
                Menu {
                    Picker("Show", selection: $model.availability) {
                        ForEach(Availability.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    chipLabel(model.availability == .all ? "On card or not" : model.availability.rawValue,
                              on: model.availability != .all, menu: true)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
            }

            if model.ratings != nil {
                Menu {
                    Button("Any genre") { model.genre = nil }
                    Divider()
                    ForEach(catalog ? model.catalogGenres(scope) : model.genreCounts(scope: scope), id: \.name) { g in
                        Button("\(g.name)  (\(g.count))") { model.genre = g.name }
                    }
                } label: {
                    chipLabel(model.genre.map { "Genre: \($0)" } ?? "Genre", on: model.genre != nil, menu: true)
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()

                Toggle(isOn: $model.ratedOnly) { chipLabel("Rated only", on: model.ratedOnly) }
                    .toggleStyle(.button).buttonStyle(.plain)
            }

            if !catalog {
                let gaps = model.coverGaps(scope: scope)
                if !gaps.missing.isEmpty || model.noCoverOnly {
                    Toggle(isOn: $model.noCoverOnly) { chipLabel("No cover (\(gaps.missing.count))", on: model.noCoverOnly) }
                        .toggleStyle(.button).buttonStyle(.plain)
                        .help("Games that show a blank tile on the Miyoo")
                }
            }

            if model.filtersActive || (catalog && model.availability != .all) {
                Button("Clear") { model.clearFilters(); model.availability = .all }.buttonStyle(.borderless).font(Fonts.body(12))
            }
            Spacer(minLength: 8)
            Text("\(shown.formatted()) shown").font(Fonts.mono(11)).foregroundStyle(Palette.mute)
        }
        .padding(.vertical, 8)
        .overlay(Rectangle().fill(Palette.rule).frame(height: 1), alignment: .top)
        .overlay(Rectangle().fill(Palette.rule).frame(height: 1), alignment: .bottom)
    }

    func chipLabel(_ text: String, on: Bool, menu: Bool = false) -> some View {
        HStack(spacing: 5) {
            Text(text).font(Fonts.medium(12)).lineLimit(1)
            if menu { Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)) }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .foregroundStyle(on ? Palette.paper : Palette.ink)
        .background(on ? Palette.ink : Color.clear)
        .overlay(Rectangle().strokeBorder(on ? Palette.ink : Palette.rule, lineWidth: 1))
        .contentShape(Rectangle())
    }
}

/// Shown only while "No cover" is on: says what's missing and offers the one fix.
struct CoverBanner: View {
    @Environment(AppModel.self) private var model
    var scope: LibraryScope

    var body: some View {
        let gaps = model.coverGaps(scope: scope)
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(gaps.missing.isEmpty ? "Every game here has a cover on the Miyoo."
                                          : "\(gaps.missing.count) game\(gaps.missing.count == 1 ? "" : "s") show a blank tile on the Miyoo.")
                    .font(Fonts.medium(13))
                if !gaps.missing.isEmpty {
                    Text(gaps.fillable.isEmpty
                         ? "None of them are in the LaunchBox database, so their covers need adding by hand."
                         : "LaunchBox has covers for \(gaps.fillable.count). The rest don't match a known game.")
                        .font(Fonts.body(12))
                }
            }
            .foregroundStyle(Palette.lcdInk)
            Spacer()
            if !gaps.fillable.isEmpty {
                Button("Save \(gaps.fillable.count) cover\(gaps.fillable.count == 1 ? "" : "s") to card") {
                    Task { await model.saveCovers(scope: scope) }
                }
                .buttonStyle(PixelButtonStyle(prominent: true))
                .fixedSize()
                .disabled(model.activity != nil)
            }
        }
        .padding(14)
        .background(Palette.lcd)
    }
}

struct GameTile: View {
    var game: Game
    var meta: GameMeta?
    var selected: Bool
    var favorite: Bool

    var body: some View {
        let info = SystemCatalog.info(for: game.system)
        VStack(alignment: .leading, spacing: 8) {
            ArtView(game: game, meta: meta)
                .aspectRatio(1, contentMode: .fit)
                .overlay(alignment: .topLeading) {
                    Rectangle().fill(info.color).frame(height: 4)
                }
                .overlay(alignment: .topTrailing) {
                    if favorite {
                        Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Palette.paper)
                            .padding(5).background(Palette.button).padding(6)
                    }
                }
                .overlay(Rectangle().strokeBorder(selected ? Palette.ink : Palette.rule, lineWidth: selected ? 2 : 1))
            Text(game.title).font(Fonts.medium(12)).foregroundStyle(Palette.ink).lineLimit(2, reservesSpace: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                Text(meta?.year.map(String.init) ?? info.name).font(Fonts.mono(10)).foregroundStyle(Palette.mute).lineLimit(1)
                Spacer(minLength: 0)
                RatingView(meta: meta, compact: true)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct GameMenu: View {
    @Environment(AppModel.self) private var model
    var game: Game
    var body: some View {
        Button(model.isFavorite(game) ? "Remove from Favorites" : "Add to Favorites") { model.toggleFavorite(game) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.url]) }
        Divider()
        Button("Delete from card…", role: .destructive) { model.selectedGame = game.id }
    }
}

struct GameDetail: View {
    @Environment(AppModel.self) private var model
    var game: Game
    @State private var confirmDelete = false

    var body: some View {
        let meta = model.meta(for: game)
        let info = SystemCatalog.info(for: game.system)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ArtView(game: game, meta: meta)
                    .frame(maxWidth: .infinity).frame(height: 260)
                    .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: 1))
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        SystemIcon(folder: game.system, size: 16)
                        Eyebrow(text: info.name + (meta?.year.map { " · \($0)" } ?? ""))
                    }
                    Text(meta?.name ?? game.title).font(Fonts.pixel(24)).foregroundStyle(Palette.ink)
                        .fixedSize(horizontal: false, vertical: true)
                    if meta?.name != nil && meta?.name != game.title {
                        Text(game.fileName).font(Fonts.mono(10)).foregroundStyle(Palette.mute)
                    }
                }
                RatingView(meta: meta)
                HStack(spacing: 8) {
                    Button(model.isFavorite(game) ? "In Favorites" : "Add to Favorites") { model.toggleFavorite(game) }
                        .buttonStyle(PixelButtonStyle(prominent: !model.isFavorite(game)))
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([game.url]) }
                        .buttonStyle(PixelButtonStyle())
                }
                if let meta {
                    VStack(alignment: .leading, spacing: 6) {
                        if let g = meta.genres { LabeledRow(label: "Genre", value: g.replacingOccurrences(of: "; ", with: ", ")) }
                        if let d = meta.developer { LabeledRow(label: "Developer", value: d) }
                        if let p = meta.publisher, p != meta.developer { LabeledRow(label: "Publisher", value: p) }
                        if let p = meta.players { LabeledRow(label: "Players", value: "\(p)") }
                    }
                    if let o = meta.overview {
                        Text(o).font(Fonts.body(12.5)).foregroundStyle(Palette.ink).lineSpacing(3)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: 14) {
                        if let u = meta.launchBoxURL { Link("Reviews on LaunchBox", destination: u) }
                        if let w = meta.wikipedia, let u = URL(string: w) { Link("Wikipedia", destination: u) }
                        if let v = meta.video, let u = URL(string: v) { Link("Video", destination: u) }
                    }
                    .font(Fonts.body(12))
                    if game.artURL == nil, meta.boxArtURL != nil {
                        Button("Save this cover to the card") { Task { await model.saveBoxArt(for: game) } }
                            .buttonStyle(PixelButtonStyle())
                    }
                } else {
                    Text(model.ratings == nil
                         ? "Download the ratings database from Device to see reviews, genres and covers."
                         : "No match in the LaunchBox database. Fan hacks and renamed files often won't match.")
                        .font(Fonts.body(12)).foregroundStyle(Palette.mute)
                }
                Divider().overlay(Palette.rule)
                VStack(alignment: .leading, spacing: 6) {
                    LabeledRow(label: "Size", value: game.size.bytes)
                    LabeledRow(label: "Folder", value: "Roms/" + (game.relPath as NSString).deletingLastPathComponent)
                }
                Button("Delete from card…") { confirmDelete = true }
                    .buttonStyle(.borderless).foregroundStyle(Palette.warn).font(Fonts.body(12))
            }
            .padding(20)
        }
        .background(Palette.paper)
        .confirmationDialog("Delete \(game.title)?", isPresented: $confirmDelete) {
            Button("Delete \(game.size.bytes)", role: .destructive) { model.delete(game) }
        } message: {
            Text("This removes the game and its box art from the card. Saves stay. It can't be undone unless you have a backup.")
        }
    }
}
