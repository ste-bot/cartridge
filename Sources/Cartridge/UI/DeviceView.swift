import SwiftUI

struct DeviceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let s = model.snapshot {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero(s)
                    HStack(alignment: .top, spacing: 16) {
                        osPanel(s)
                        careP(s)
                    }
                    themes(s)
                }
                .padding(28)
                .frame(maxWidth: 1100, alignment: .leading)
            }
        }
    }

    // The card, drawn, with the numbers that matter next to it.
    func hero(_ s: CardSnapshot) -> some View {
        let used = Double(s.usedBytes) / Double(max(1, s.totalBytes))
        return HStack(alignment: .bottom, spacing: 28) {
            SDCardGraphic(used: used).frame(width: 120)
            VStack(alignment: .leading, spacing: 10) {
                Eyebrow(text: "Miyoo Mini Plus · \(s.volumeName)")
                Text(s.freeBytes.bytes + " free").font(Fonts.pixel(44)).foregroundStyle(Palette.ink)
                Text("\(s.usedBytes.bytes) used by \(s.games.count.formatted()) games, saves and the OS on a \(s.totalBytes.bytes) card.")
                    .font(Fonts.body(13)).foregroundStyle(Palette.mute)
                SegmentMeter(value: used, segments: 24, height: 12).frame(maxWidth: 420)
            }
        }
    }

    func osPanel(_ s: CardSnapshot) -> some View {
        let installed = s.osVersion
        let known = OnionUpdates.parse(installed) != nil
        return Panel {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "Operating system")
                HStack(alignment: .firstTextBaseline) {
                    Text("Onion").font(Fonts.pixel(26))
                    Text(known ? installed : "repack").font(Fonts.pixel(26)).foregroundStyle(Palette.button)
                }
                if !known {
                    Text("This card runs a community build (“\(installed)”), so the exact Onion version isn't recorded.")
                        .font(Fonts.body(12)).foregroundStyle(Palette.mute).fixedSize(horizontal: false, vertical: true)
                }
                LabeledRow(label: "RetroArch", value: s.retroArchVersion ?? "—")
                LabeledRow(label: "Emulators", value: "\(Set(s.emulators.map(\.romFolder)).count) systems")
                Divider().overlay(Palette.rule)
                if s.updateStaged && !known {
                    Text("An update is copied to the card. Eject it and turn the Miyoo on to finish installing.")
                        .font(Fonts.medium(12)).foregroundStyle(Palette.lcdInk)
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Palette.lcd)
                }
                if let r = model.latestStable {
                    let newer = OnionUpdates.isNewer(r.version, than: installed)
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Latest stable: \(r.version)").font(Fonts.medium(13))
                            if let d = r.published_at { Text(d.formatted(date: .abbreviated, time: .omitted)).font(Fonts.mono(11)).foregroundStyle(Palette.mute) }
                        }
                        Spacer()
                        if s.updateStaged && !known {
                            Text("Copied, waiting for boot").font(Fonts.mono(11)).foregroundStyle(Palette.mute)
                        } else if newer || !known {
                            Button("Copy update to card") { Task { await model.stageUpdate(r) } }
                                .buttonStyle(PixelButtonStyle(prominent: true))
                                .disabled(model.activity != nil)
                        } else {
                            Text("Up to date").font(Fonts.mono(11)).foregroundStyle(Palette.mute)
                        }
                    }
                    if let b = model.latestBeta {
                        HStack {
                            Text("Beta build" + (b.published_at.map { " · " + $0.formatted(date: .abbreviated, time: .omitted) } ?? ""))
                                .font(Fonts.body(12)).foregroundStyle(Palette.mute)
                            Spacer()
                            Link("Release notes", destination: b.html_url).font(Fonts.body(12))
                        }
                    }
                } else if let e = model.releaseError {
                    HStack {
                        Text(e).font(Fonts.body(12)).foregroundStyle(Palette.warn)
                        Spacer()
                        Button("Try again") { Task { await model.loadReleases() } }.buttonStyle(PixelButtonStyle())
                    }
                } else {
                    ProgressView().controlSize(.small)
                }
            }
        }
    }

    func careP(_ s: CardSnapshot) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: 14) {
                Eyebrow(text: "Card care")
                CareRow(title: "Back up the card", detail: "Copies everything (games, saves, settings) to a folder on this Mac.",
                        action: "Back up…") { Task { await model.backUp() } }
                CareRow(title: "Ratings database", detail: model.ratingsStatus,
                        action: model.ratings == nil ? "Download" : "Update") { Task { await model.downloadRatings() } }
                if model.ratings != nil {
                    let gaps = model.coverGaps(scope: .all)
                    if gaps.fillable.isEmpty {
                        CareRow(title: "Covers", detail: gaps.missing.isEmpty ? "Every game has a cover." :
                                    "\(gaps.missing.count) games have no cover and none match LaunchBox.",
                                action: "Review") { model.noCoverOnly = true; model.section = .library(.all) }
                    } else {
                        CareRow(title: "Fill in missing covers",
                                detail: "\(gaps.missing.count) games show a blank tile on the Miyoo. LaunchBox has \(gaps.fillable.count) of them.",
                                action: "Save \(gaps.fillable.count)") { Task { await model.saveCovers(scope: .all) } }
                    }
                }
                CareRow(title: "Eject", detail: "Unmounts the card safely so you can put it back in the Miyoo.",
                        action: "Eject") { model.eject() }
                CareRow(title: "Show in Finder", detail: s.root.path, action: "Open") {
                    NSWorkspace.shared.open(s.root)
                }
            }
        }
        .disabled(model.activity != nil)
    }

    func themes(_ s: CardSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Themes").font(Fonts.pixel(22))
                Text("\(s.themes.count) on the card · change on the Miyoo under Apps → Themes")
                    .font(Fonts.body(12)).foregroundStyle(Palette.mute)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 14)], spacing: 14) {
                ForEach(s.themes) { t in
                    let active = s.activeThemePath.map { t.url.path.hasSuffix($0) } ?? false
                    VStack(alignment: .leading, spacing: 6) {
                        LocalImage(url: t.preview).aspectRatio(4 / 3, contentMode: .fit)
                            .overlay(Rectangle().strokeBorder(active ? Palette.button : Palette.rule, lineWidth: active ? 3 : 1))
                        HStack {
                            Text(t.name).font(Fonts.body(12)).lineLimit(1)
                            Spacer()
                            if active { Text("IN USE").font(Fonts.mono(9)).foregroundStyle(Palette.button) }
                        }
                    }
                }
            }
        }
    }
}

struct LabeledRow: View {
    var label: String
    var value: String
    var body: some View {
        HStack {
            Text(label).font(Fonts.body(12)).foregroundStyle(Palette.mute)
            Spacer()
            Text(value).font(Fonts.mono(12))
        }
    }
}

struct CareRow: View {
    var title: String
    var detail: String
    var action: String
    var perform: () -> Void
    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Fonts.medium(13))
                Text(detail).font(Fonts.body(11)).foregroundStyle(Palette.mute).lineLimit(2)
            }
            Spacer()
            Button(action, action: perform).buttonStyle(PixelButtonStyle())
        }
    }
}

struct LocalImage: View {
    var url: URL
    @State private var image: NSImage?
    var body: some View {
        ZStack {
            Rectangle().fill(Palette.panel)
            if let image { Image(nsImage: image).resizable().interpolation(.none).aspectRatio(contentMode: .fill) }
            else { Dither(0.15, ink: Palette.mute, pixel: 3) }
        }
        .clipped()
        .task(id: url) { image = await Task.detached { NSImage(contentsOf: url) }.value }
    }
}
