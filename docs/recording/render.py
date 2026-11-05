#!/usr/bin/env python3
"""Render frames from capture.sh into an animated GIF.

    ./render.py FRAMES OUT.gif COLS ROWS FONTSIZE FIRST LAST STEP

The pane is parsed into a grid of styled cells, drawn with the same font the
terminal uses, and written out with the real inter-frame delays taken from the
capture's timestamps. FIRST..LAST trims the capture to the tour itself -- see
the last captioned frame capture.sh reports -- and STEP thins the frame rate.

Needs Pillow, which does not have to be installed system-wide:

    python3 -m venv venv && ./venv/bin/pip install pillow
    ./venv/bin/python render.py ../../../frames demo.gif 140 38 12 0 875 1
"""

import glob
import os
import re
import sys
import unicodedata

from PIL import Image, ImageDraw, ImageFont

FONT_DIR = os.environ.get("FC_FONT_DIR", "/usr/share/fonts/TTF")
FONTS = {
    (False, False): "JetBrainsMonoNerdFontMono-Regular.ttf",
    (True, False): "JetBrainsMonoNerdFontMono-Bold.ttf",
    (False, True): "JetBrainsMonoNerdFontMono-Italic.ttf",
    (True, True): "JetBrainsMonoNerdFontMono-BoldItalic.ttf",
}

ANSI16 = [
    (0x14, 0x16, 0x1B), (0xE8, 0x6A, 0x74), (0x8C, 0xC3, 0x9E), (0xE0, 0xC0, 0x7B),
    (0x7A, 0xA2, 0xF7), (0xBB, 0x9A, 0xF7), (0x7D, 0xCF, 0xFF), (0xC0, 0xC5, 0xCE),
    (0x54, 0x5C, 0x7E), (0xF7, 0x86, 0x8E), (0x9E, 0xCE, 0x6A), (0xE0, 0xAF, 0x68),
    (0x8A, 0xB4, 0xF8), (0xC6, 0xA0, 0xF6), (0x89, 0xDD, 0xFF), (0xE6, 0xE9, 0xF0),
]

# JetBrainsMono has no glyph for the five characters Claude's TUI leans on
# hardest -- the spinner frames, the tool-call bracket and the diff marker.
# A terminal falls back per glyph; PIL does not, so do it by hand.
FALLBACK_DIR = os.environ.get("FC_FALLBACK_DIR", "/usr/share/fonts/Adwaita")
FALLBACK = {False: "AdwaitaMono-Regular.ttf", True: "AdwaitaMono-Bold.ttf"}
FALLBACK_CHARS = frozenset("\u23bf\u2722\u273b\u273d\u29c9")

# Lines and corners a terminal draws itself, edge to edge in the cell, rather
# than taking from the font: that is what makes them join without a seam. The
# font's own glyphs are thinner and soft at the joins.
BOX_CHARS = frozenset("─━│╭╮╰╯▏╎")

SGR = re.compile(r"\x1b\[([0-9;:]*)m")
OSC = re.compile(r"\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)")


def hex_colour(value, fallback):
    if not value:
        return fallback
    value = value.lstrip("#")
    return tuple(int(value[i : i + 2], 16) for i in (0, 2, 4))


# What the terminal paints where Neovim asks for its default colours. Recording
# in a config with a colourscheme, set these to its Normal highlight: Neovim
# writes that background out on some rows and leaves others to the terminal,
# and a mismatch shows as bands behind the code.
DEFAULT_FG = hex_colour(os.environ.get("FC_FG"), (0xE0, 0xE2, 0xEA))
DEFAULT_BG = hex_colour(os.environ.get("FC_BG"), (0x14, 0x16, 0x1B))


def xterm256(n):
    if n < 16:
        return ANSI16[n]
    if n < 232:
        n -= 16
        levels = [0, 95, 135, 175, 215, 255]
        return (levels[n // 36], levels[(n // 6) % 6], levels[n % 6])
    v = 8 + (n - 232) * 10
    return (v, v, v)


class Style:
    __slots__ = ("fg", "bg", "bold", "italic", "underline", "reverse")

    def __init__(self):
        self.reset()

    def reset(self):
        self.fg = None
        self.bg = None
        self.bold = False
        self.italic = False
        self.underline = False
        self.reverse = False


def apply_sgr(st, params):
    codes = [int(p) if p else 0 for p in params.replace(":", ";").split(";")] if params else [0]
    i = 0
    while i < len(codes):
        c = codes[i]
        if c == 0:
            st.reset()
        elif c == 1:
            st.bold = True
        elif c == 3:
            st.italic = True
        elif c == 4:
            st.underline = True
        elif c == 7:
            st.reverse = True
        elif c in (21, 22):
            st.bold = False
        elif c == 23:
            st.italic = False
        elif c == 24:
            st.underline = False
        elif c == 27:
            st.reverse = False
        elif 30 <= c <= 37:
            st.fg = ANSI16[c - 30]
        elif c == 39:
            st.fg = None
        elif 40 <= c <= 47:
            st.bg = ANSI16[c - 40]
        elif c == 49:
            st.bg = None
        elif 90 <= c <= 97:
            st.fg = ANSI16[c - 90 + 8]
        elif 100 <= c <= 107:
            st.bg = ANSI16[c - 100 + 8]
        elif c in (38, 48):
            target = "fg" if c == 38 else "bg"
            if i + 1 < len(codes) and codes[i + 1] == 2:
                setattr(st, target, tuple(codes[i + 2 : i + 5]))
                i += 4
            elif i + 1 < len(codes) and codes[i + 1] == 5:
                setattr(st, target, xterm256(codes[i + 2]))
                i += 2
        i += 1


def cell(ch, st):
    fg = st.fg or DEFAULT_FG
    bg = st.bg or DEFAULT_BG
    if st.reverse:
        fg, bg = bg, fg
    return (ch, fg, bg, st.bold, st.italic)


def parse_frame(text, cols, rows):
    """One pane capture -> rows of (char, fg, bg, bold, italic) cells."""
    grid = []
    for line in text.split("\n")[:rows]:
        line = OSC.sub("", line)
        st = Style()
        cells = []
        pos = 0
        for m in SGR.finditer(line):
            for c in line[pos : m.start()]:
                cells.append(cell(c, st))
                if unicodedata.east_asian_width(c) in ("W", "F"):
                    cells.append(None)
            apply_sgr(st, m.group(1))
            pos = m.end()
        for c in line[pos:]:
            cells.append(cell(c, st))
            if unicodedata.east_asian_width(c) in ("W", "F"):
                cells.append(None)
        # capture-pane strips trailing blanks; carry the row's last background
        # out to the edge rather than punching a hole in the float.
        tail = st.bg or DEFAULT_BG
        while len(cells) < cols:
            cells.append((" ", DEFAULT_FG, tail, False, False))
        grid.append(cells[:cols])
    while len(grid) < rows:
        grid.append([(" ", DEFAULT_FG, DEFAULT_BG, False, False)] * cols)
    return grid


def box(d, c, col, row, cw, ch, fill):
    """Draw a box-drawing character the way a terminal does: strokes from the
    cell's centre out to its edges, at a thickness that scales with the cell."""
    t = max(1, round(cw / 7))
    x0, x1 = round(col * cw), round((col + 1) * cw)
    y0, y1 = row * ch, (row + 1) * ch
    lx = round(col * cw + cw / 2 - t / 2)  # the vertical stroke's left pixel
    ly = y0 + (ch - t) // 2  # the horizontal stroke's top pixel
    # The video keeps one colour per 2x2 block of pixels. A 2px stroke that
    # straddles two blocks has its colour averaged with the background's on
    # both sides; started on an even pixel, it fills its blocks exactly.
    if t % 2 == 0:
        lx -= lx % 2
        ly -= ly % 2
    r = max(2, round(cw / 2))

    # A corner's straight leg can come out empty once the stroke is snapped
    # to an even pixel -- the arc already reaches the cell's edge.
    def rect(b, fill):
        if b[2] >= b[0] and b[3] >= b[1]:
            d.rectangle(b, fill=fill)

    if c == "─":
        rect([x0, ly, x1 - 1, ly + t - 1], fill=fill)
    elif c == "━":
        rect([x0, ly - t // 2, x1 - 1, ly + t - 1 + (t + 1) // 2], fill=fill)
    elif c == "│":
        rect([lx, y0, lx + t - 1, y1 - 1], fill=fill)
    elif c == "╎":
        gap = max(1, ch // 8)
        mid = y0 + ch // 2
        rect([lx, y0 + gap // 2, lx + t - 1, mid - gap // 2 - 1], fill=fill)
        rect([lx, mid + gap // 2, lx + t - 1, y1 - gap // 2 - 1], fill=fill)
    elif c == "▏":
        rect([x0, y0, x0 + max(1, round(cw / 8)) - 1, y1 - 1], fill=fill)
    elif c == "╭":
        d.arc([lx, ly, lx + 2 * r, ly + 2 * r], 180, 270, fill=fill, width=t)
        rect([lx + r, ly, x1 - 1, ly + t - 1], fill=fill)
        rect([lx, ly + r, lx + t - 1, y1 - 1], fill=fill)
    elif c == "╮":
        right = lx + t - 1
        d.arc([right - 2 * r, ly, right, ly + 2 * r], 270, 360, fill=fill, width=t)
        rect([x0, ly, right - r, ly + t - 1], fill=fill)
        rect([lx, ly + r, right, y1 - 1], fill=fill)
    elif c == "╰":
        bottom = ly + t - 1
        d.arc([lx, bottom - 2 * r, lx + 2 * r, bottom], 90, 180, fill=fill, width=t)
        rect([lx + r, ly, x1 - 1, bottom], fill=fill)
        rect([lx, y0, lx + t - 1, bottom - r], fill=fill)
    elif c == "╯":
        right, bottom = lx + t - 1, ly + t - 1
        d.arc([right - 2 * r, bottom - 2 * r, right, bottom], 0, 90, fill=fill, width=t)
        rect([x0, ly, right - r, bottom], fill=fill)
        rect([lx, y0, right, bottom - r], fill=fill)


def draw(grid, cols, rows, fonts, cw, ch, pad):
    alt = fonts["fallback"]
    img = Image.new("RGB", (round(cols * cw), rows * ch), DEFAULT_BG)
    d = ImageDraw.Draw(img)
    # Every background first, then every glyph: a glyph that hangs below its
    # cell -- the foot of Claude's `⎿` -- would otherwise be painted over by the
    # next row's background, and read as a plain bar.
    for y, line in enumerate(grid):
        x = 0
        while x < cols:
            c = line[x]
            if c is None:
                x += 1
                continue
            run = x
            while run < cols and line[run] is not None and line[run][2] == c[2]:
                run += 1
            if c[2] != DEFAULT_BG:
                d.rectangle(
                    [round(x * cw), y * ch, round(run * cw) - 1, (y + 1) * ch - 1], fill=c[2]
                )
            x = run
    for y, line in enumerate(grid):
        # One draw call per run of identical style: 5000-odd cells a frame is
        # far too many individual text calls.
        x = 0
        while x < cols:
            c = line[x]
            if c is None or c[0] == " ":
                x += 1
                continue
            if c[0] in BOX_CHARS:
                box(d, c[0], x, y, cw, ch, c[1])
                x += 1
                continue
            if c[0] in FALLBACK_CHARS:
                font = alt[c[3]]
                off = (cw - font.getlength(c[0])) / 2
                d.text((x * cw + off, y * ch + pad), c[0], font=font, fill=c[1])
                x += 1
                continue
            key = (c[1], c[3], c[4])
            start = x
            run = []
            while (x < cols and line[x] is not None
                   and (line[x][1], line[x][3], line[x][4]) == key
                   and line[x][0] not in FALLBACK_CHARS
                   and line[x][0] not in BOX_CHARS):
                run.append(line[x][0])
                x += 1
            d.text((start * cw, y * ch + pad), "".join(run).rstrip(),
                   font=fonts[(key[1], key[2])], fill=key[0])
    return img


def font(directory, name, size):
    path = os.path.join(directory, name)
    if not os.path.exists(path):
        raise SystemExit(
            f"missing font: {path}\n"
            "Set FC_FONT_DIR / FC_FALLBACK_DIR, or install JetBrainsMono Nerd Font\n"
            "and Adwaita Mono. The fallback covers the five glyphs Claude's TUI\n"
            "uses that JetBrainsMono has no image for."
        )
    return ImageFont.truetype(path, size)


def metrics(size):
    fonts = {k: font(FONT_DIR, v, size) for k, v in FONTS.items()}
    fonts["fallback"] = {b: font(FALLBACK_DIR, v, size) for b, v in FALLBACK.items()}
    # The font's exact advance, not a rounded one. Runs of text are drawn as one
    # string, which the font lays out at its own advance (7.203px at size 12):
    # with the cell rounded to 7px a 128-cell run ended 26px right of where the
    # cell grid put it, so the float's right border landed in a different column
    # on every row.
    cw = fonts[(False, False)].getlength("M")
    ch = round(size * 1.32)
    return fonts, cw, ch, (ch - size) // 2


def main():
    src, out = sys.argv[1], sys.argv[2]
    cols, rows, size = int(sys.argv[3]), int(sys.argv[4]), int(sys.argv[5])
    first, last, step = int(sys.argv[6]), int(sys.argv[7]), int(sys.argv[8])

    fonts, cw, ch, pad = metrics(size)
    names = sorted(glob.glob(os.path.join(src, "*.txt")))[first : last + 1 : step]
    print(f"{len(names)} frames -> {round(cols * cw)}x{rows * ch}, cell {cw:.3f}x{ch}", flush=True)

    images, times = [], []
    for i, name in enumerate(names):
        times.append(int(open(name[:-4] + ".time").read().strip()))
        text = open(name, encoding="utf-8", errors="replace").read()
        images.append(draw(parse_frame(text, cols, rows), cols, rows, fonts, cw, ch, pad))
        if i % 50 == 0:
            print(f"  {i}/{len(names)}", flush=True)

    durations = [max(20, times[i + 1] - times[i]) for i in range(len(times) - 1)]
    durations.append(durations[-1] if durations else 80)

    cache = os.path.join(src, "..", "cache")
    os.makedirs(cache, exist_ok=True)
    for i, im in enumerate(images):
        im.save(os.path.join(cache, f"{i:04d}.png"))
    with open(os.path.join(cache, "durations.txt"), "w") as fh:
        fh.write("\n".join(str(d) for d in durations))

    encode(images, durations, out, 128)


def encode(images, durations, out, colors):
    """disposal=1 leaves the previous frame in place, so Pillow can store only
    the rectangle that changed. disposal=2 clears to background first, which
    forces every frame to carry the whole screen."""
    pal = images[len(images) // 3].convert("P", palette=Image.ADAPTIVE, colors=colors)
    frames = [im.quantize(palette=pal, dither=Image.NONE) for im in images]
    frames[0].save(out, save_all=True, append_images=frames[1:], duration=durations,
                   loop=0, optimize=True, disposal=1)
    print(f"{out}  {os.path.getsize(out) / 1e6:.2f} MB  {sum(durations) / 1000:.1f}s", flush=True)


if __name__ == "__main__":
    main()
