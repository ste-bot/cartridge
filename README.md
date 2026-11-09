# Cartridge

A native macOS app for managing a **Miyoo Mini / Mini Plus** SD card running **[Onion OS](https://github.com/OnionUI/Onion)**. Put the card in your Mac's card reader and Cartridge reads it directly.

- **Device:** shows free space, the Onion and RetroArch versions, and the latest Onion release from GitHub. One click copies an update to the card. It can also back up the whole card, eject it, and show your installed themes.
- **Emulators:** lists every system with its emulator and core. It checks BIOS files (required and optional) and installs or removes emulators using the Package Manager packages Onion already keeps on the card.
- **Library:** shows every game with box art, community ratings, genre, year and description from the [LaunchBox Games Database](https://gamesdb.launchbox-app.com).
  - Search, sort and filter by genre, rating or missing cover.
  - Favorites write to `Roms/favourite.json`, so they show up on the device.
  - Delete games, and fill in missing covers so the Miyoo stops showing blank tiles.
  - Drop ROM files on the window or on a system in the sidebar; each file goes to the right folder by its extension.

Cartridge doesn't include or download any games.

## Build

Requires macOS 15+ and Xcode 16+ (Swift 6).

```bash
git clone https://github.com/ste-bot/cartridge
cd cartridge
scripts/bundle.sh          # builds dist/Cartridge.app
open dist/Cartridge.app
```

The app icon is drawn by `scripts/make_icon.py`, which needs Python 3 with Pillow (`pip install pillow`). Without it the app still builds, just with the default icon.

For development, `swift run` works too. These launch arguments open a specific screen:
`--args -pane device|emulators|favorites|system:GBA`, `-select "GBA/Game.gba"` and `-nocover YES`.

## Data and privacy

- **Ratings:** on first use, Cartridge downloads LaunchBox's public `Metadata.zip` (about 110 MB) to `~/Library/Application Support/Cartridge/`. It indexes the retro systems Onion supports (around 42k games) so lookups work offline. Device → Ratings database → Update refreshes it.
- **Covers:** fetched from `images.launchbox-app.com` on demand and cached in `~/Library/Caches/Cartridge/covers`.
- **Onion releases:** read from the GitHub API.
- **Your library:** nothing about it leaves your Mac.

## How it understands the card

| Location on the card | What Cartridge does with it |
|---|---|
| `Emu/*/config.json`, `RApp/*/config.json` | Emulators, their ROM folders, file extensions and cores |
| `Roms/<SYSTEM>/` | Games; `Imgs/<name>.png` is the box art the Miyoo shows |
| `Roms/<SYSTEM>/*_cache6.db` | Onion's list cache, removed after changes so the device rescans |
| `Roms/favourite.json` | Favorites, one JSON object per line |
| `BIOS/` | BIOS checks; FinalBurn Neo `.dat` files give arcade games their real titles |
| `App/PackageManager/data/` | Emulator packages that can be installed or removed |
| `Icons/Default/` | Hardware icons for each system |
| `.tmp_update/onionVersion/version.txt` | Installed Onion version |

## Design

- **Palette:** taken from handheld hardware. The background is console plastic grey and the text is label ink. Panels use the olive of an unlit LCD. The one accent is the magenta-maroon of the A/B buttons.
- **Fills:** everything filled (storage, rating meters, empty art) is a 4×4 Bayer dither on a hard pixel grid, never a gradient.
- **Type:** Geist Pixel is for titles and numbers only. Body text is Geist and data is Geist Mono.

## Not affiliated

Cartridge is an independent project. It isn't affiliated with Miyoo, the Onion team, or LaunchBox. Game metadata and covers belong to their respective owners and contributors.

## License

MIT for the code. The bundled Geist fonts are under the SIL Open Font License 1.1.
