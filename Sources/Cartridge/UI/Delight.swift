import SwiftUI

// MARK: - Delight
//
// A handful of rare moments get character; everything frequent stays instant.
// Motion here is frame-stepped, like a handheld LCD redrawing, never a smooth tween.
// With Reduce Motion on, each moment shows its final state immediately.

/// One LCD "refresh" in the stepped sequences below.
private let lcdFrame: Duration = .milliseconds(55)

/// Shown over the window when a card mounts: contacts light one by one, the card fills to its used space,
/// and the free space counts up. About a second; click to skip.
struct BootSplash: View {
    var snapshot: CardSnapshot
    var onDone: () -> Void

    @State private var fill = 0.0
    @State private var lit = 0
    @State private var shownFree: Int64 = 0

    var used: Double { Double(snapshot.usedBytes) / Double(max(1, snapshot.totalBytes)) }

    var body: some View {
        VStack(spacing: 16) {
            SDCardGraphic(used: fill, lit: lit).frame(width: 120)
            VStack(spacing: 6) {
                Text(snapshot.volumeName).font(Fonts.pixel(22)).foregroundStyle(Palette.ink)
                Text("\(shownFree.bytes) free").font(Fonts.mono(12)).foregroundStyle(Palette.mute)
                    .opacity(fill > 0 ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper)
        .contentShape(Rectangle())
        .onTapGesture { onDone() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.volumeName) mounted")
        .task {
            for i in 1...5 { lit = i; try? await Task.sleep(for: lcdFrame) }
            let steps = 8
            for i in 1...steps {
                fill = used * Double(i) / Double(steps)
                shownFree = snapshot.freeBytes * Int64(i) / Int64(steps)
                try? await Task.sleep(for: lcdFrame)
            }
            try? await Task.sleep(for: .milliseconds(320))
            onDone()
        }
    }
}

/// The no-card screen right after an eject: the card empties and its contacts go dark in reverse,
/// then an LCD panel says it's safe to remove.
struct EjectedView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var ejected: AppModel.Ejected

    @State private var fill: Double
    @State private var lit = 5
    @State private var done = false

    init(ejected: AppModel.Ejected) {
        self.ejected = ejected
        _fill = State(initialValue: ejected.used)
    }

    var body: some View {
        VStack(spacing: 18) {
            SDCardGraphic(used: fill, lit: lit).frame(width: 90)
            LCDPanel(text: "Safe to remove").opacity(done ? 1 : 0)
            Text("\(ejected.name) is ejected. Put it back in the Miyoo, or insert it again to keep working on it.")
                .font(Fonts.body(13)).foregroundStyle(Palette.mute).multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("Look again") { Task { await model.refresh() } }.buttonStyle(PixelButtonStyle())
        }
        .padding(40)
        .task {
            if reduceMotion { fill = 0; lit = 0; done = true; return }
            let steps = 8
            for i in stride(from: steps - 1, through: 0, by: -1) {
                fill = ejected.used * Double(i) / Double(steps)
                try? await Task.sleep(for: lcdFrame)
            }
            for i in stride(from: 4, through: 0, by: -1) { lit = i; try? await Task.sleep(for: lcdFrame) }
            done = true
        }
    }
}

/// The Miyoo's own screen: olive LCD, dark pixel type. Used for messages about the device itself.
struct LCDPanel: View {
    var text: String
    var body: some View {
        Text(text.uppercased()).font(Fonts.pixel(15)).tracking(1)
            .foregroundStyle(Palette.lcdInk)
            .padding(.horizontal, 14).frame(height: Control.height + 8)
            .background(Palette.lcd)
            .overlay(Rectangle().strokeBorder(Palette.lcdInk.opacity(0.5), lineWidth: 1).padding(3))
    }
}

/// A 9×9 pixel star for the empty Favorites screen, drawn on the pixel grid like the rest of the art.
struct PixelStar: View {
    var pixel: CGFloat = 6
    private static let rows = [
        "....#....",
        "....#....",
        "...###...",
        "#########",
        ".#######.",
        "..#####..",
        "..##.##..",
        ".##...##.",
        ".#.....#.",
    ]

    var body: some View {
        Canvas { ctx, _ in
            for (y, row) in Self.rows.enumerated() {
                for (x, c) in row.enumerated() where c == "#" {
                    ctx.fill(Path(CGRect(x: CGFloat(x) * pixel, y: CGFloat(y) * pixel, width: pixel, height: pixel)),
                             with: .color(Palette.button))
                }
            }
        }
        .frame(width: pixel * 9, height: pixel * 9)
        .accessibilityHidden(true)
    }
}
