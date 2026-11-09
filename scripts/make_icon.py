"""Draws the Cartridge app icon: a pixel cartridge with a dithered label, on a 1024 canvas."""
import sys
from PIL import Image, ImageDraw

out = sys.argv[1]
S, U = 1024, 32                      # 32×32 pixel grid, each cell 32px
img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)
BAYER = [[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]

def cell(x, y, c):
    d.rectangle([x * U, y * U, (x + 1) * U - 1, (y + 1) * U - 1], fill=c)

paper, ink, plum, lcd = (226, 228, 222), (28, 31, 35), (142, 44, 105), (157, 170, 136)

# rounded-square backdrop (macOS icon grid ~ 824px body)
d.rounded_rectangle([100, 100, 924, 924], radius=180, fill=paper)
# cartridge body: x 9..22, y 6..25, notch top-right
for y in range(6, 26):
    for x in range(9, 23):
        if y == 6 and x >= 21:
            continue
        cell(x, y, ink)
# label: dithered plum ramp, x 11..20, y 8..17
for y in range(8, 18):
    for x in range(11, 21):
        t = (y - 8) / 9
        cell(x, y, plum if (BAYER[y % 4][x % 4] + 0.5) / 16 < 0.9 - 0.6 * t else lcd)
# grip ridges
for x in (11, 13, 15, 17, 19):
    cell(x, 21, paper); cell(x, 22, paper)
# contacts
for x in range(11, 21, 2):
    cell(x, 25, (90, 94, 98))
img.save(out)
