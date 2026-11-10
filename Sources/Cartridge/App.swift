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
                .background(TransparentTitlebar())
                .onAppear {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    // `-fullscreen YES` opens straight into full screen (used for screenshots).
                    if UserDefaults.standard.bool(forKey: "fullscreen") {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            NSApplication.shared.windows.first { $0.isVisible }?.toggleFullScreen(nil)
                        }
                    }
                }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var booting: CardSnapshot?

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
            .overlay {
                // Covers only the main area, so the sidebar fills in with the card's systems underneath.
                if let b = booting {
                    BootSplash(snapshot: b) { booting = nil }
                        .transition(.opacity.animation(Motion.toastOut))
                }
            }
        }
        .overlay(alignment: .bottom) { StatusOverlay() }
        .tint(Palette.button)
        .onChange(of: model.snapshot == nil) { wasNil, isNil in
            if wasNil && !isNil && !reduceMotion { booting = model.snapshot }
        }
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
    @AppStorage("sidebar.libraryOpen") private var libraryOpen = true
    @AppStorage("sidebar.systemsOpen") private var systemsOpen = true

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.section }, set: { if let v = $0 { model.section = v } })) {
            Section {
                row("Device", glyph: navIcon("sdcard", .device), pane: .device)
                row("Emulators", glyph: navIcon("cpu", .emulators), pane: .emulators)
            }
            Section(isExpanded: $libraryOpen) {
                row("All games", count: model.games.count, glyph: AnyView(Image(systemName: "square.grid.2x2")), pane: .library(.all))
                row("Favorites", count: model.snapshot?.favorites.count ?? 0, glyph: AnyView(Image(systemName: "star")), pane: .library(.favorites))
            } header: { header("Library", isOpen: $libraryOpen) }
            Section(isExpanded: $systemsOpen) {
                ForEach(model.systems(), id: \.info.folder) { s in
                    row(s.info.name, count: s.count, glyph: AnyView(SystemIcon(folder: s.info.folder, size: 20)),
                        pane: .library(.system(s.info.folder)))
                        .dropDestination(for: URL.self) { urls, _ in
                            Task { await model.addGames(urls, to: s.info.folder) }
                            return true
                        }
                }
            } header: { header("Systems", isOpen: $systemsOpen) }
        }
        .font(Fonts.body(13))
        .safeAreaInset(edge: .bottom) { CardBadge() }
    }

    /// Every sidebar row shares one geometry: icons left-aligned in a 22pt column, labels on one text column,
    /// counts on the trailing edge.
    func row(_ title: String, count: Int? = nil, glyph: AnyView, pane: Pane) -> some View {
        SidebarRow(selected: model.section == pane) {
            HStack(spacing: 8) {
                glyph.frame(width: 22, alignment: .leading)
                Text(title)
                Spacer()
                if let count { Text("\(count)").font(Fonts.mono(11)).foregroundStyle(.secondary) }
            }
        }
        .tag(pane)
    }

    /// Accent-tinted, except on the selected row where the system's selected style keeps it legible on the highlight.
    func navIcon(_ symbol: String, _ pane: Pane) -> AnyView {
        model.section == pane ? AnyView(Image(systemName: symbol)) : AnyView(Image(systemName: symbol).foregroundStyle(Palette.button))
    }

    /// Section headers start on the icons' left edge (the system inset is 2pt shy of the row content).
    /// The whole title is a click target for collapsing its section, not just the hover chevron.
    func header(_ title: String, isOpen: Binding<Bool>) -> some View {
        Button { withAnimation(Motion.reflow) { isOpen.wrappedValue.toggle() } } label: {
            Text(title).padding(.leading, 2).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOpen.wrappedValue ? "Expanded" : "Collapsed")
        .accessibilityHint("Shows or hides the section")
    }
}

/// A soft wash behind the row under the pointer, sized to sit where the system selection highlight draws.
/// Fill and corner match the toolbar's sidebar toggle hover, so the two read as one control family.
/// No fade: the sidebar is scanned dozens of times a day, so the state follows the pointer instantly.
struct SidebarRow<Content: View>: View {
    var selected: Bool
    @ViewBuilder var content: Content
    @State private var hovering = false

    var body: some View {
        content
            .contentShape(Rectangle())
            .background {
                if hovering && !selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Palette.ink.opacity(0.03))
                        .padding(.horizontal, -8).padding(.vertical, -4)
                }
            }
            .onHover { hovering = $0 }
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
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(Palette.panel)
            .overlay(Rectangle().frame(height: 1).foregroundStyle(Palette.rule), alignment: .top)
        }
    }
}

struct NoCardView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let e = model.ejected { EjectedView(ejected: e) } else { waiting }
    }

    var waiting: some View {
        VStack(spacing: 18) {
            SDCardGraphic(used: 0, lit: 0).frame(width: 90)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .transition(Motion.toast(reduceMotion: reduceMotion))
            }
            if let n = model.notice {
                let lcd = model.noticeIsLCD
                HStack(spacing: 10) {
                    Text(n).font(lcd ? Fonts.pixel(13) : Fonts.medium(12)).foregroundStyle(lcd ? Palette.lcdInk : Palette.paper)
                    Button { model.notice = nil } label: { Image(systemName: "xmark").foregroundStyle(lcd ? Palette.lcdInk : Palette.paper) }
                        .buttonStyle(.plain).accessibilityLabel("Dismiss")
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(lcd ? Palette.lcd : Palette.ink)
                .overlay { if lcd { Rectangle().strokeBorder(Palette.lcdInk.opacity(0.5), lineWidth: 1).padding(3) } }
                .transition(Motion.toast(reduceMotion: reduceMotion))
                .id(n)
                .task(id: n) {
                    try? await Task.sleep(for: .seconds(5))
                    if model.notice == n { model.notice = nil }
                }
            }
        }
        .padding(.bottom, 18)
        .animation(Motion.reflow, value: model.activity != nil)
        .animation(Motion.reflow, value: model.notice)
    }
}


/// The title bar's grey band started 2pt left of the split divider, notching the sidebar's top corner.
/// A transparent title bar removes the band, so the divider runs unbroken to the top of the window.
struct TransparentTitlebar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { v.window?.titlebarAppearsTransparent = true }
        return v
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.titlebarAppearsTransparent = true
    }
}
