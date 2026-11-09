import SwiftUI

/// A BIOS requirement: any one of `files` present in /BIOS satisfies it.
struct BiosRequirement: Hashable {
    let files: [String]
    let required: Bool
    let purpose: String
}

/// Static knowledge about a ROM folder on an Onion card.
struct SystemInfo: Hashable {
    let folder: String
    let name: String
    let maker: String
    let platforms: [String]          // LaunchBox platform names
    let hex: UInt32                  // cartridge colour
    let bios: [BiosRequirement]
    let gameIsFolder: Bool           // ScummVM-style: each game is a directory

    var color: Color { Color(hex: hex) }
}

enum SystemCatalog {
    static let all: [SystemInfo] = [
        .init(folder: "GB", name: "Game Boy", maker: "Nintendo", platforms: ["Nintendo Game Boy"], hex: 0x8F9491,
              bios: [.init(files: ["gb_bios.bin"], required: false, purpose: "Boot logo (optional)")], gameIsFolder: false),
        .init(folder: "GBC", name: "Game Boy Color", maker: "Nintendo", platforms: ["Nintendo Game Boy Color"], hex: 0x2F8A84,
              bios: [.init(files: ["gbc_bios.bin"], required: false, purpose: "Boot logo (optional)")], gameIsFolder: false),
        .init(folder: "GBA", name: "Game Boy Advance", maker: "Nintendo", platforms: ["Nintendo Game Boy Advance"], hex: 0x4A4F9A,
              bios: [.init(files: ["gba_bios.bin"], required: false, purpose: "Improves accuracy")], gameIsFolder: false),
        .init(folder: "FC", name: "NES", maker: "Nintendo", platforms: ["Nintendo Entertainment System", "Nintendo Famicom Disk System"], hex: 0xB0412F,
              bios: [.init(files: ["disksys.rom"], required: false, purpose: "Famicom Disk System games")], gameIsFolder: false),
        .init(folder: "SFC", name: "Super Nintendo", maker: "Nintendo", platforms: ["Super Nintendo Entertainment System"], hex: 0x8A82B6,
              bios: [], gameIsFolder: false),
        .init(folder: "NDS", name: "Nintendo DS", maker: "Nintendo", platforms: ["Nintendo DS"], hex: 0x9EA4AB,
              bios: [], gameIsFolder: false),
        .init(folder: "GW", name: "Game & Watch", maker: "Nintendo", platforms: ["Nintendo Game & Watch"], hex: 0xB49B45,
              bios: [], gameIsFolder: false),
        .init(folder: "MD", name: "Mega Drive", maker: "Sega", platforms: ["Sega Genesis"], hex: 0x3B3B3D,
              bios: [], gameIsFolder: false),
        .init(folder: "MS", name: "Master System", maker: "Sega", platforms: ["Sega Master System"], hex: 0x56698A,
              bios: [], gameIsFolder: false),
        .init(folder: "GG", name: "Game Gear", maker: "Sega", platforms: ["Sega Game Gear"], hex: 0x2E3A48,
              bios: [], gameIsFolder: false),
        .init(folder: "SEGACD", name: "Sega CD", maker: "Sega", platforms: ["Sega CD"], hex: 0x3B5A7F,
              bios: [.init(files: ["bios_CD_U.bin", "bios_CD_E.bin", "bios_CD_J.bin"], required: true, purpose: "Needed to boot any disc")], gameIsFolder: false),
        .init(folder: "THIRTYTWOX", name: "32X", maker: "Sega", platforms: ["Sega 32X"], hex: 0x8C4A3A,
              bios: [], gameIsFolder: false),
        .init(folder: "PS", name: "PlayStation", maker: "Sony", platforms: ["Sony Playstation"], hex: 0x6C7983,
              bios: [.init(files: ["scph1001.bin", "scph5501.bin", "scph101.bin", "psxonpsp660.bin"], required: true, purpose: "Real BIOS for full compatibility")], gameIsFolder: false),
        .init(folder: "PCE", name: "PC Engine", maker: "NEC", platforms: ["NEC TurboGrafx-16", "NEC TurboGrafx-CD"], hex: 0xC7642C,
              bios: [.init(files: ["syscard3.pce"], required: false, purpose: "Needed for CD games")], gameIsFolder: false),
        .init(folder: "NGP", name: "Neo Geo Pocket", maker: "SNK", platforms: ["SNK Neo Geo Pocket Color", "SNK Neo Geo Pocket"], hex: 0x678A57,
              bios: [], gameIsFolder: false),
        .init(folder: "NEOCD", name: "Neo Geo CD", maker: "SNK", platforms: ["SNK Neo Geo CD"], hex: 0x7D6A3C,
              bios: [.init(files: ["neocd/neocd.bin", "neocd/front-sp1.bin", "neocd/top-sp1.bin", "neocd/neocd_f.rom"], required: true, purpose: "Neo Geo CD system ROM")], gameIsFolder: false),
        .init(folder: "ARCADE", name: "Arcade", maker: "Various", platforms: ["Arcade"], hex: 0xB8862A,
              bios: [.init(files: ["neogeo.zip"], required: false, purpose: "Neo Geo arcade games")], gameIsFolder: false),
        .init(folder: "FBNEO", name: "FinalBurn Neo", maker: "Arcade", platforms: ["Arcade"], hex: 0xA97A28,
              bios: [.init(files: ["neogeo.zip"], required: false, purpose: "Neo Geo arcade games")], gameIsFolder: false),
        .init(folder: "FBA2012", name: "FB Alpha 2012", maker: "Arcade", platforms: ["Arcade"], hex: 0x9C7027,
              bios: [], gameIsFolder: false),
        .init(folder: "MAME2000", name: "MAME 2000", maker: "Arcade", platforms: ["Arcade"], hex: 0x8F6726,
              bios: [], gameIsFolder: false),
        .init(folder: "ADVMAME", name: "AdvanceMAME", maker: "Arcade", platforms: ["Arcade"], hex: 0x845E24,
              bios: [], gameIsFolder: false),
        .init(folder: "MBA", name: "MAME (MBA)", maker: "Arcade", platforms: ["Arcade"], hex: 0x7A5722,
              bios: [], gameIsFolder: false),
        .init(folder: "DOS", name: "MS-DOS", maker: "PC", platforms: ["MS-DOS"], hex: 0x4C6C5B,
              bios: [], gameIsFolder: false),
        .init(folder: "SCUMMVM", name: "ScummVM", maker: "PC", platforms: ["ScummVM"], hex: 0x7A5D3E,
              bios: [], gameIsFolder: true),
        .init(folder: "PICO", name: "PICO-8", maker: "Lexaloffle", platforms: ["PICO-8"], hex: 0xD24E6E,
              bios: [], gameIsFolder: false),
        .init(folder: "PORTS", name: "Ports", maker: "Native", platforms: [], hex: 0x5B5B78,
              bios: [], gameIsFolder: false),
        .init(folder: "OPENBOR", name: "OpenBOR", maker: "Engine", platforms: [], hex: 0x6E5470,
              bios: [], gameIsFolder: true),
        .init(folder: "PANASONIC", name: "3DO", maker: "Panasonic", platforms: ["3DO Interactive Multiplayer"], hex: 0x55606B,
              bios: [.init(files: ["panafz10.bin", "panafz1.bin", "goldstar.bin"], required: true, purpose: "3DO system ROM")], gameIsFolder: false),
    ]

    static let byFolder: [String: SystemInfo] = Dictionary(uniqueKeysWithValues: all.map { ($0.folder, $0) })

    static func info(for folder: String) -> SystemInfo {
        byFolder[folder] ?? SystemInfo(folder: folder, name: folder.capitalized, maker: "Other", platforms: [],
                                       hex: 0x7C807C, bios: [], gameIsFolder: false)
    }

    static var allPlatforms: Set<String> { Set(all.flatMap(\.platforms)) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
