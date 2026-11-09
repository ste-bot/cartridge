import SwiftUI

struct EmulatorsView: View {
    @Environment(AppModel.self) private var model
    @State private var filter = ""
    @State private var showAll = false

    var body: some View {
        if let s = model.snapshot {
            let folders = Set(s.romFolders).union(s.emulators.map(\.romFolder))
                .subtracting(["SEARCH"])
                .sorted { SystemCatalog.info(for: $0).name < SystemCatalog.info(for: $1).name }
            let counts = Dictionary(grouping: s.games, by: \.system)
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Emulators").font(Fonts.pixel(32))
                        Text("What each system runs on, whether its BIOS is in place, and what's missing.")
                            .font(Fonts.body(13)).foregroundStyle(Palette.mute)
                    }
                    VStack(spacing: 0) {
                        ForEach(folders.filter { f in showAll || !(counts[f] ?? []).isEmpty || s.emulators.contains { $0.romFolder == f } }, id: \.self) { f in
                            SystemRow(info: SystemCatalog.info(for: f),
                                      emulators: s.emulators.filter { $0.romFolder == f },
                                      games: counts[f] ?? [],
                                      bios: model.biosStatus(for: SystemCatalog.info(for: f)))
                            Rectangle().fill(Palette.rule).frame(height: 1)
                        }
                    }
                    .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: 1))
                    packages(s)
                }
                .padding(28)
                .frame(maxWidth: 1100, alignment: .leading)
            }
        }
    }

    func packages(_ s: CardSnapshot) -> some View {
        let list = s.packages.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
        let groups = Dictionary(grouping: list, by: \.vendor).sorted { $0.key < $1.key }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Add or remove").font(Fonts.pixel(22))
                Text("\(s.packages.count) packages from Onion's Package Manager, already on your card")
                    .font(Fonts.body(12)).foregroundStyle(Palette.mute)
                Spacer()
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12)], alignment: .leading, spacing: 12) {
                ForEach(groups, id: \.key) { vendor, items in
                    Panel {
                        VStack(alignment: .leading, spacing: 8) {
                            Eyebrow(text: vendor)
                            ForEach(items) { p in PackageRow(package: p) }
                        }
                    }
                }
            }
        }
    }
}

struct SystemRow: View {
    var info: SystemInfo
    var emulators: [EmulatorConfig]
    var games: [Game]
    var bios: [BiosStatus]

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            SystemIcon(folder: info.folder, size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(info.name).font(Fonts.strong(14))
                Text(info.maker).font(Fonts.body(11)).foregroundStyle(Palette.mute)
            }
            .frame(minWidth: 110, idealWidth: 150, maxWidth: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if emulators.isEmpty {
                    Text("No emulator on the card").font(Fonts.medium(12)).foregroundStyle(Palette.warn)
                    Text("If these games don't show on the Miyoo, install a package for Roms/\(info.folder) below.")
                        .font(Fonts.body(11)).foregroundStyle(Palette.mute).fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(emulators) { e in
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(e.label).font(Fonts.medium(12)).lineLimit(1)
                                if e.kind == "RApp" { Text("EXPERT").font(Fonts.mono(9)).foregroundStyle(Palette.mute) }
                            }
                            if let c = e.core { Text(c + " core").font(Fonts.mono(10)).foregroundStyle(Palette.mute).lineLimit(1) }
                        }
                    }
                }
            }
            .frame(minWidth: 140, maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if bios.isEmpty {
                    Text("No BIOS needed").font(Fonts.body(11)).foregroundStyle(Palette.mute)
                }
                ForEach(bios) { b in
                    HStack(spacing: 6) {
                        Image(systemName: b.found != nil ? "checkmark.square.fill" : (b.requirement.required ? "xmark.square.fill" : "square.dashed"))
                            .foregroundStyle(b.found != nil ? Palette.ink : (b.requirement.required ? Palette.warn : Palette.mute))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(b.found ?? b.requirement.files[0]).font(Fonts.mono(11))
                            Text(b.found != nil ? b.requirement.purpose : (b.requirement.required ? "Missing · " : "Optional · ") + b.requirement.purpose)
                                .font(Fonts.body(10)).foregroundStyle(Palette.mute)
                        }
                    }
                }
            }
            .frame(minWidth: 160, idealWidth: 230, maxWidth: 230, alignment: .leading)
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(games.count)").font(Fonts.pixel(20)).foregroundStyle(games.isEmpty ? Palette.mute : Palette.ink)
                Text(games.isEmpty ? "games" : games.reduce(0) { $0 + $1.size }.bytes).font(Fonts.mono(10)).foregroundStyle(Palette.mute)
            }
            .frame(width: 70, alignment: .trailing)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Palette.panel)
    }
}

struct PackageRow: View {
    @Environment(AppModel.self) private var model
    var package: PackageInfo
    @State private var confirmRemove = false

    var body: some View {
        let installed = model.isInstalled(package)
        HStack {
            Text(package.title).font(Fonts.body(12)).lineLimit(1)
            if package.kind == "RApp" { Text("EXPERT").font(Fonts.mono(9)).foregroundStyle(Palette.mute) }
            Spacer()
            if installed {
                Button("Remove") { confirmRemove = true }.buttonStyle(.borderless).font(Fonts.body(11)).foregroundStyle(Palette.mute)
            } else {
                Button("Install") { Task { await model.install(package) } }.buttonStyle(PixelButtonStyle())
            }
        }
        .disabled(model.activity != nil)
        .confirmationDialog("Remove \(package.title)?", isPresented: $confirmRemove) {
            Button("Remove emulator", role: .destructive) { Task { await model.uninstall(package) } }
        } message: {
            Text("Games and saves stay on the card. You can install it again from this list.")
        }
    }
}
