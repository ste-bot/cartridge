import AppKit
import SwiftUI

@main
struct CartridgeApp: App {
    @State private var model = AppModel()

    init() {
        Fonts.registerFonts()
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Cartridge") {
            RootView()
                .environment(model)
                .frame(minWidth: 980, minHeight: 620)
                .onAppear { NSApplication.shared.activate(ignoringOtherApps: true) }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .newItem) {
                Button("Refresh Card") { Task { await model.refresh() } }.keyboardShortcut("r")
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
        } detail: {
            Group {
                if model.snapshot == nil {
                    NoCardView()
                } else {
                    switch model.section {
                    case .device: DeviceView()
                    case .emulators: EmulatorsView()
                    case .library(let scope): LibraryView(scope: scope)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.paper)
        }
        .overlay(alignment: .bottom) { StatusOverlay() }
        .tint(Palette.button)
        .onChange(of: model.section) { _, _ in
            // Genres and gaps differ per system, so a filter from one view would silently empty the next.
            model.genre = nil
            model.selectedCatalog = nil
            model.noCoverOnly = false
        }
    }
}

struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.section }, set: { if let v = $0 { model.section = v } })) {
            Section {
                Label { Text("Device") } icon: { Image(systemName: "sdcard") }.tag(Pane.device)
                Label { Text("Emulators") } icon: { Image(systemName: "cpu") }.tag(Pane.emulators)
            }
            Section("Library") {
                row("All games", count: model.games.count, glyph: AnyView(Image(systemName: "square.grid.2x2"))).tag(Pane.library(.all))
                row("Favorites", count: model.snapshot?.favorites.count ?? 0, glyph: AnyView(Image(systemName: "star"))).tag(Pane.library(.favorites))
            }
            Section("Systems") {
                ForEach(model.systems(), id: \.info.folder) { s in
                    row(s.info.name, count: s.count, glyph: AnyView(SystemIcon(folder: s.info.folder, size: 20)))
                        .tag(Pane.library(.system(s.info.folder)))
                        .dropDestination(for: URL.self) { urls, _ in
                            Task { await model.addGames(urls, to: s.info.folder) }
                            return true
                        }
                }
            }
        }
        .font(Fonts.body(13))
        .safeAreaInset(edge: .bottom) { CardBadge() }
    }

    func row(_ title: String, count: Int, glyph: AnyView) -> some View {
        HStack(spacing: 8) {
            glyph.frame(width: 22)
            Text(title)
            Spacer()
            Text("\(count)").font(Fonts.mono(11)).foregroundStyle(Palette.mute)
        }
    }
}

struct CardBadge: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let s = model.snapshot {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(s.volumeName).font(Fonts.pixel(13))
                    Spacer()
                    Button { model.eject() } label: { Image(systemName: "eject") }
                        .buttonStyle(.borderless).help("Eject card")
                }
                SegmentMeter(value: Double(s.usedBytes) / Double(max(1, s.totalBytes)), segments: 12, height: 6)
                Text("\(s.freeBytes.bytes) free of \(s.totalBytes.bytes)").font(Fonts.mono(10)).foregroundStyle(Palette.mute)
            }
            .padding(12)
            .background(Palette.panel)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Palette.rule), alignment: .top)
        }
    }
}

struct NoCardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 18) {
            SDCardGraphic(used: 0).frame(width: 90)
            Text("Insert the Miyoo's microSD card").font(Fonts.pixel(22)).foregroundStyle(Palette.ink)
            Text("Cartridge reads Onion cards straight from the card reader. It opens automatically once the card mounts.")
                .font(Fonts.body(13)).foregroundStyle(Palette.mute).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("Look again") { Task { await model.refresh() } }.buttonStyle(PixelButtonStyle())
        }
        .padding(40)
    }
}

struct StatusOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            if let a = model.activity {
                HStack(spacing: 12) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(a.title).font(Fonts.strong(12))
                        Text(a.detail).font(Fonts.mono(11)).foregroundStyle(Palette.mute).lineLimit(1)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Palette.panel)
                .overlay(Rectangle().strokeBorder(Palette.ink, lineWidth: 1))
            }
            if let n = model.notice {
                HStack(spacing: 10) {
                    Text(n).font(Fonts.medium(12)).foregroundStyle(Palette.paper)
                    Button { model.notice = nil } label: { Image(systemName: "xmark").foregroundStyle(Palette.paper) }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Palette.ink)
                .task(id: n) {
                    try? await Task.sleep(for: .seconds(5))
                    if model.notice == n { model.notice = nil }
                }
            }
        }
        .padding(.bottom, 18)
        .animation(.easeOut(duration: 0.15), value: model.activity != nil)
        .animation(.easeOut(duration: 0.15), value: model.notice)
    }
}
