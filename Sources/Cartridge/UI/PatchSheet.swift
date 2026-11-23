import AppKit
import SwiftUI

/// Drives the Patch ROM sheet: find the patch (GitHub link or file), find the base ROM it was made for,
/// then patch and copy the result to the card.
@MainActor @Observable
final class PatchFlow {
    enum Step: Equatable { case input, busy(String), ready, failed(String) }

    var link = ""
    var step: Step = .input
    var resolved: GitHubPatches.Resolved?
    var assets: [GitHubRelease.Asset] = []
    var asset: GitHubRelease.Asset?
    var files: [URL] = []                 // patch files on the Mac (downloaded or picked)
    var file: URL?
    var header: PatchHeader?
    var base: URL?
    var baseSearched = false
    var name = ""
    var nameLocked = false                // set once the user edits it, or when updating a game
    var cover: NSImage?
    var useCover = true
    var updating: Game?
    /// The card's Roms folder, searched first for a base ROM.
    var cardRoms: URL?

    var isBusy: Bool { if case .busy = step { return true } else { return false } }

    func start(_ r: PatchRequest, cardRoms: URL?) async {
        self.cardRoms = cardRoms
        link = r.link
        updating = r.updating
        if let g = r.updating { name = g.stem; nameLocked = true }
        if let f = r.file { await use(files: [f]) } else if !link.isEmpty { await lookUp() }
    }

    func lookUp() async {
        reset()
        step = .busy("Looking up the release on GitHub…")
        do {
            let r = try await GitHubPatches.resolve(link)
            resolved = r
            assets = r.patches.isEmpty ? r.zips : r.patches
            asset = assets.first { $0.name == r.preferred } ?? assets.first
            if let u = r.release.imageURL { Task { cover = await RemoteImages.shared.image(for: u) } }
            if let a = asset { await download(a) }
        } catch { step = .failed(error.localizedDescription) }
    }

    func download(_ a: GitHubRelease.Asset) async {
        asset = a
        step = .busy("Downloading \(a.name) (\(Int64(a.size).bytes))…")
        do {
            let found = try await GitHubPatches.download(a)
            guard !found.isEmpty else { throw PatchError("“\(a.name)” has no BPS, UPS or IPS patch inside.") }
            await use(files: found)
        } catch { step = .failed(error.localizedDescription) }
    }

    func use(files f: [URL]) async {
        files = f
        if let first = f.first { await load(first) }
    }

    func load(_ f: URL) async {
        file = f
        base = nil; baseSearched = false
        step = .busy("Reading \(f.lastPathComponent)…")
        do {
            let h = try await Task.detached { try Patcher.header(of: [UInt8](try Data(contentsOf: f))) }.value
            header = h
            if !nameLocked {
                name = PatchNaming.suggestedName(repo: resolved?.repo, patchFile: f.lastPathComponent, baseCRC: h.sourceCRC)
            }
            step = .ready
            await findBase()
        } catch { step = .failed(error.localizedDescription) }
    }

    /// Looks for the exact base ROM the patch names: on the card first, then folders used before, then Downloads.
    func findBase() async {
        guard let h = header, let size = h.sourceSize, let crc = h.sourceCRC else { baseSearched = true; return }
        let folders = (cardRoms.map { [$0] } ?? []) + KnownBase.searchFolders
        base = await Task.detached { KnownBase.find(size: size, crc: crc, in: folders) }.value
        baseSearched = true
    }

    func chooseBase() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.prompt = "Use as Base"
        panel.message = header?.sourceCRC.map { crc in
            "Choose \(KnownBase.name(crc) ?? "the clean ROM this patch was made for") (CRC32 \(Patcher.hex(crc)))."
        } ?? "Choose the clean ROM this patch was made for. IPS patches don't say which one, so check the hack's instructions."
        guard panel.runModal() == .OK, let u = panel.url else { return }
        if let h = header, let crc = h.sourceCRC, Patcher.crc32(of: u) != crc {
            step = .failed("“\(u.lastPathComponent)” isn't the right base ROM. This patch needs CRC32 \(Patcher.hex(crc))"
                           + (KnownBase.name(crc).map { " (\($0))" } ?? "") + ".")
            return
        }
        KnownBase.remember(folderOf: u)
        base = u
        step = .ready
    }

    func choosePatchFile() async {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.prompt = "Use Patch"
        panel.message = "Choose a .bps, .ups or .ips patch."
        guard panel.runModal() == .OK, let u = panel.url else { return }
        reset()
        link = ""
        await use(files: [u])
    }

    private func reset() {
        resolved = nil; assets = []; asset = nil; files = []; file = nil; header = nil
        base = nil; baseSearched = false; cover = nil
        if !nameLocked { name = "" }
    }

    var baseLabel: String? {
        guard let base else { return nil }
        return KnownBase.name(header?.sourceCRC) ?? base.lastPathComponent
    }

    func apply(model: AppModel, system: String, ext: String) async -> Bool {
        guard let file, let base else { return false }
        let fileName = AppModel.safeFileName(name.trimmingCharacters(in: .whitespaces))
        guard !fileName.isEmpty else { step = .failed("Give the game a name."); return false }
        step = .busy("Patching \(base.lastPathComponent)…")
        do {
            let rom = try await Task.detached {
                try Patcher.apply([UInt8](try Data(contentsOf: file)), to: [UInt8](try Data(contentsOf: base)))
            }.value
            let art = useCover ? cover?.squarePNG(side: 250) : nil
            let source = PatchSource(link: link.isEmpty ? nil : link, repo: resolved?.repo, tag: resolved?.release.tag_name,
                                     patchName: file.lastPathComponent, baseCRC: header?.sourceCRC.map(Patcher.hex), patched: Date())
            step = .busy("Copying to the card…")
            try await model.installPatched(rom: rom, name: fileName, ext: ext, system: system, cover: art, source: source)
            return true
        } catch {
            step = .failed(error.localizedDescription)
            return false
        }
    }
}

struct PatchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PatchRequest
    @State private var flow = PatchFlow()

    /// The system comes from the base ROM's extension (.gba → GBA).
    private var system: String? {
        guard let b = flow.base else { return nil }
        let s = model.systemsAccepting(b)
        return s.count == 1 ? s[0] : nil
    }
    private var ext: String { flow.base?.pathExtension.lowercased() ?? "" }
    private var existing: Game? {
        guard let system else { return flow.updating }
        return model.existingGame(named: flow.name, system: system)
    }
    private var sameVersion: Bool {
        guard let e = existing, let tag = flow.resolved?.release.tag_name else { return false }
        return model.patchSource(for: e)?.tag == tag
    }

    var body: some View {
        @Bindable var flow = flow
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow(text: flow.updating == nil ? "Patch a ROM" : "Update")
                Text(flow.updating?.stem ?? "Patch a ROM").font(Fonts.pixel(26)).foregroundStyle(Palette.ink)
                Text("Paste a GitHub link to a ROM hack, or use a patch file. Cartridge finds your clean base ROM, patches it and puts the game on the card. It never downloads games, only patches.")
                    .font(Fonts.body(12)).foregroundStyle(Palette.mute).fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    TextField("github.com/owner/repo or a release link", text: $flow.link)
                        .textFieldStyle(.roundedBorder).font(Fonts.body(13))
                        .onSubmit { Task { await flow.lookUp() } }
                    Button("Look up") { Task { await flow.lookUp() } }
                        .buttonStyle(PixelButtonStyle())
                        .disabled(flow.link.trimmingCharacters(in: .whitespaces).isEmpty || flow.isBusy)
                }
                Button("Or choose a patch file…") { Task { await flow.choosePatchFile() } }
                    .buttonStyle(PixelLinkStyle()).font(Fonts.body(12)).disabled(flow.isBusy)
            }

            if flow.file != nil || flow.resolved != nil { details }

            status
            Spacer(minLength: 0)
            footer
        }
        .padding(24)
        .frame(width: 560)
        .frame(minHeight: 300)
        .background(Palette.paper)
        .dropDestination(for: URL.self) { urls, _ in
            guard let u = urls.first else { return false }
            Task {
                if u.isFileURL { await flow.use(files: [u]) } else { flow.link = u.absoluteString; await flow.lookUp() }
            }
            return true
        }
        .task { await flow.start(request, cardRoms: model.snapshot?.roms) }
    }

    @ViewBuilder private var details: some View {
        @Bindable var flow = flow
        Panel {
            VStack(alignment: .leading, spacing: 12) {
                if let r = flow.resolved {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Release").font(Fonts.body(12)).foregroundStyle(Palette.mute)
                        Spacer()
                        Link("\(r.repo) · \(r.release.tag_name)", destination: r.release.html_url)
                            .font(Fonts.mono(12)).buttonStyle(PixelLinkStyle(color: Palette.ink))
                    }
                    if flow.assets.count > 1, let current = flow.asset {
                        Picker("Patch", selection: Binding(get: { current }, set: { a in Task { await flow.download(a) } })) {
                            ForEach(flow.assets, id: \.self) { Text($0.name).tag($0) }
                        }
                        .font(Fonts.body(12)).disabled(flow.isBusy)
                    }
                }
                if flow.files.count > 1, let current = flow.file {
                    Picker("Patch in archive", selection: Binding(get: { current }, set: { f in Task { await flow.load(f) } })) {
                        ForEach(flow.files, id: \.self) { Text($0.lastPathComponent).tag($0) }
                    }
                    .font(Fonts.body(12)).disabled(flow.isBusy)
                }
                if let f = flow.file, let h = flow.header {
                    LabeledRow(label: "Patch", value: "\(f.lastPathComponent) · \(h.format.rawValue)")
                }
                baseRow
                if flow.header != nil {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Text("Name").font(Fonts.body(12)).foregroundStyle(Palette.mute)
                            TextField("Game name", text: Binding(get: { flow.name }, set: { flow.name = $0; flow.nameLocked = true }))
                                .textFieldStyle(.roundedBorder).font(Fonts.body(13))
                        }
                        Text(nameNote).font(Fonts.body(11.5)).foregroundStyle(existing == nil ? Palette.mute : Palette.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if let img = flow.cover {
                    HStack(spacing: 12) {
                        Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
                            .frame(width: 56, height: 56).clipped()
                            .overlay(Rectangle().strokeBorder(Palette.rule, lineWidth: 1))
                        Toggle("Use the release's first image as box art", isOn: $flow.useCover)
                            .toggleStyle(.checkbox).font(Fonts.body(12))
                    }
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var baseRow: some View {
        if let label = flow.baseLabel {
            HStack(alignment: .firstTextBaseline) {
                Text("Base ROM").font(Fonts.body(12)).foregroundStyle(Palette.mute)
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("✓ " + label).font(Fonts.mono(12)).foregroundStyle(Palette.ink)
                    Text(flow.base?.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~") ?? "")
                        .font(Fonts.mono(10)).foregroundStyle(Palette.mute).lineLimit(1).truncationMode(.middle)
                }
            }
        } else if let h = flow.header, flow.baseSearched || h.sourceCRC == nil {
            VStack(alignment: .leading, spacing: 8) {
                Text(h.sourceCRC.map { crc in
                    "Needs \(KnownBase.name(crc) ?? "a clean base ROM") (CRC32 \(Patcher.hex(crc))). It isn't on the card or in Downloads."
                } ?? "IPS patches don't say which ROM they're for. Choose the clean ROM named in the hack's instructions.")
                    .font(Fonts.body(12)).foregroundStyle(Palette.warn).fixedSize(horizontal: false, vertical: true)
                Button("Choose base ROM…") { flow.chooseBase() }.buttonStyle(PixelButtonStyle(size: .wide))
            }
        } else if flow.header != nil {
            LabeledRow(label: "Base ROM", value: "Looking…")
        }
    }

    private var nameNote: String {
        guard let system else { return "Saved under Roms on the card." }
        let path = "Roms/\(system)/\(AppModel.safeFileName(flow.name)).\(ext)"
        if sameVersion, let tag = flow.resolved?.release.tag_name {
            return "\(path) is already \(tag), the latest release. Patching again replaces it with the same build."
        }
        if let e = existing {
            let from = model.patchSource(for: e)?.tag.map { " (\($0))" } ?? ""
            return "Replaces \(e.fileName)\(from) on the card. Your save carries over because the name stays the same."
        }
        return "Saved as \(path). Leave versions out of the name so updates keep your save."
    }

    @ViewBuilder private var status: some View {
        switch flow.step {
        case .busy(let msg):
            HStack(spacing: 8) { ProgressView().controlSize(.small); Text(msg).font(Fonts.body(12)).foregroundStyle(Palette.mute) }
        case .failed(let msg):
            Text(msg).font(Fonts.body(12)).foregroundStyle(Palette.warn).fixedSize(horizontal: false, vertical: true)
        default: EmptyView()
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel") { dismiss() }.buttonStyle(PixelButtonStyle()).keyboardShortcut(.cancelAction)
            Button(existing == nil ? "Patch and add to card" : "Update on card") {
                Task {
                    guard let system else { return }
                    if await flow.apply(model: model, system: system, ext: ext) { dismiss() }
                }
            }
            .buttonStyle(PixelButtonStyle(prominent: true, size: .wide))
            .keyboardShortcut(.defaultAction)
            .disabled(flow.base == nil || system == nil || flow.isBusy || flow.name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
}
